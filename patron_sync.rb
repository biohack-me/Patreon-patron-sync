#!/usr/bin/env ruby

#####################################################################
### functions
#####################################################################

# authenticates to the API using the user-specific access token.
# that access token should have been previously generated using the client
# token and secret for the application- see
# https://www.patreon.com/portal/start/quick-start
def connect_to_patreon
  if !File.exist?('credentials.rb')
    puts "You need to populate the credentials.rb file."
    puts "See credentials.rb.example for more details."
    exit 1
  end
  require_relative 'credentials.rb'

  if PATREON_ACCESS_TOKEN.empty?
    puts "PATREON_ACCESS_TOKEN not set in credentials.rb."
    exit 1
  end

  require 'patreon'
  Patreon::API.new(PATREON_ACCESS_TOKEN)
end

def connect_to_vanilla
  if !File.exist?('credentials.rb')
    puts "You need to populate the credentials.rb file."
    puts "See credentials.rb.example for more details."
    exit 1
  end
  require_relative 'credentials.rb'

  if  DB_HOST.empty? || DB_USER.empty? || DB_PASS.empty? || DB_DB.empty?
    puts "Database credentials not provided in credentials.rb."
    exit 1
  end

  require 'mysql2'
  Mysql2::Client.new(host: DB_HOST, username: DB_USER, password: DB_PASS, database: DB_DB)
end

# get ALL the data the API will give us. it's a mess and repetitive, so
# basically unusable in this state.
def fetch_patron_data(api_client)
  api_client.fetch_campaign_and_patrons.data.first
end

# look in the previously fetched API data to get all reward levels
# returns an array containing a hash of details for each reward level
def reward_levels(patron_data)
  patron_data.rewards.collect{|r|
    {
      id:          r.id,
      type:        r.type,
      amount:      r.amount_cents,
      title:       r.title,
      description: r.description
    }
  }.sort_by{|r| r[:amount]}
end

# look in the previously fetched API data to get all patrons
# returns an array containing a hash of details for each patron and their
# rewards, if applicable
def all_patrons(patron_data)
  patron_data.pledges.collect{|p| 
    {
      full_name:    p.patron.full_name,
      email:        p.patron.email,
      amount:       p.amount_cents,
      reward_id:    (p.reward.respond_to?(:id) ? p.reward.id : nil),
      reward_title: (p.reward.respond_to?(:id) ? p.reward.title : nil)
    }
  }
end

# for the below functions, every pledge above a specific level will get a
# reward. to avoid hard coding too much (just minimum reward titles),
# programmatically get all reward levels that qualify
def all_award_levels_above(reward_title, rewards)
  relevant_levels = []
  target_found = false
  rewards.each do |reward|
    if target_found
      relevant_levels << reward[:id]
    elsif reward[:title] == reward_title
      target_found = true
      relevant_levels << reward[:id]
    end
  end
  return relevant_levels
end

# look in the vanilla database to find the earliest discussion with the given
# title (in case some joker created a duplicate discussion)
# return false if no matching discussion was found
def get_vanilla_discussion(post_title, db_conn)
  query = db_conn.prepare("select * from GDN_Discussion where Name = ? order by DateInserted ASC limit 1")
  results = query.execute(post_title)
  results.size == 1 or return false
  return results.first
end

# look in the vanilla database to find the YAGA badge with the given name
# return false if no matching badge was found
def get_badge(badge_name, db_conn)
  query = db_conn.prepare("select * from GDN_Badge where Name = ?")
  results = query.execute(badge_name)
  results.size == 1 or return false
  return results.first
end

# try to connect patrons to forum user accounts using full_name/handle or 
# email/email. returns an array of selected data from the vanilla DB
def patron_forum_users(patrons, db_conn)
  users = []
  patrons.each do |p|
    query = db_conn.prepare("select UserID, Name, Email, CountBadges from GDN_User where Name = ? or Email = ? order by UserID DESC")
    results = query.execute(p[:full_name], p[:email])
    (results.size == 0) and next
    users << results.first
  end
  return users
end

# create a new post on the virtual wall discussion with all qualifying patron
# names
def create_virtual_wall_post(reward_levels, patrons, db_conn)
  award_patrons = patrons.select{|p| reward_levels.include?(p[:reward_id])}.sort_by{|p| p[:amount]}.reverse
  users = patron_forum_users(award_patrons, db_conn)
  users.size > 0 or return false

  virtual_wall_post = get_vanilla_discussion('Patreon Virtual Wall', db_conn)
  virtual_wall_post or return false

  # build comment content
  post_content = "Thank you to this month's Patreon supporters!<br /><br /><ul>"
  users.each do |u|
    post_content << "<li>@#{u['Name']}</li>"
  end
  post_content << "</ul>"

  # create comment
  query = db_conn.prepare("insert into GDN_Comment (DiscussionID, InsertUserID, Body, Format, DateInserted) values (?, ?, ?, ?, ?)")
  results = query.execute(virtual_wall_post['DiscussionID'], virtual_wall_post['InsertUserID'], post_content, 'Html', Time.now.getutc)
  comment_id = db_conn.last_id

  # update discussion metadata
  if virtual_wall_post['FirstCommentID'].nil?
    # this is the first post!
    query = db_conn.prepare("update GDN_Discussion set FirstCommentID = ?, LastCommentID = ?, CountComments = ?, DateLastComment = ? where DiscussionID = ?")
    results = query.execute(comment_id, comment_id, virtual_wall_post['CountComments']+1, Time.now.getutc, virtual_wall_post['DiscussionID'])
  else
    query = db_conn.prepare("update GDN_Discussion set LastCommentID = ?, CountComments = ?, DateLastComment = ? where DiscussionID = ?")
    results = query.execute(comment_id, virtual_wall_post['CountComments']+1, Time.now.getutc, virtual_wall_post['DiscussionID'])
  end

  # update user metadata
  query = db_conn.prepare("update GDN_User set CountComments = CountComments + 1 where UserID = ?")
  results = query.execute(virtual_wall_post['InsertUserID'])
end

# remove a badge from all users, updating metadata
def remove_badge(badge, db_conn)
  query = db_conn.prepare("select * from GDN_BadgeAward where BadgeID = ?")
  results = query.execute(badge['BadgeID'])
  results.size > 0 or return true
  results.each do |award|
    remove_badge_award = db_conn.prepare("delete from GDN_BadgeAward where BadgeID = ? and UserID = ?")
    remove_badge_award.execute(award['BadgeID'], award['UserID'])
    update_badge_count = db_conn.prepare("update GDN_User set CountBadges = CountBadges-1 where UserID = ?")
    update_badge_count.execute(award['UserID'])
  end
end

# award a badge to a user, updating metadata
def award_badge(user, badge, db_conn)
  add_badge_award = db_conn.prepare("insert into GDN_BadgeAward (BadgeID, UserID, InsertUserID, DateInserted) values (?, ?, ?, ?)")
  add_badge_award.execute(badge['BadgeID'], user['UserID'], user['UserID'], Time.now.getutc)
  update_badge_count = db_conn.prepare("update GDN_User set CountBadges = CountBadges+1 where UserID = ?")
  update_badge_count.execute(user['UserID'])
end

# remove all old patron badges
# award new ones to qualifying accounts
def award_patreon_badges(reward_levels, patrons, db_conn)
  badge_patreon = get_badge('Patreon Badge', db_conn)
  badge_patreon or return false

  # remove all old badges
  remove_badge(badge_patreon, db_conn)

  # award new badges
  award_patrons = patrons.select{|p| reward_levels.include?(p[:reward_id])}
  users = patron_forum_users(award_patrons, db_conn)
  users.size > 0 or return false
  users.each do |user|
    award_badge(user, badge_patreon, db_conn)
  end
end

# remove all old gold patron badges
# award new ones to qualifying accounts
def award_gold_patreon_badges(reward_levels, patrons, db_conn)
  badge_gold_patreon = get_badge('Patreon Gold Badge', db_conn)
  badge_gold_patreon or return false

  # remove all old badges
  remove_badge(badge_gold_patreon, db_conn)

  # award new badges
  award_patrons = patrons.select{|p| reward_levels.include?(p[:reward_id])}
  users = patron_forum_users(award_patrons, db_conn)
  users.size > 0 or return false
  users.each do |user|
    award_badge(user, badge_gold_patreon, db_conn)
  end
end

#####################################################################
### execution
#####################################################################

# get patreon data
@api_client = connect_to_patreon
@patron_data = fetch_patron_data(@api_client)
@reward_levels = reward_levels(@patron_data)
@patrons = all_patrons(@patron_data)
@virtual_wall_levels = all_award_levels_above('Patreon Virtual Wall', @reward_levels)
@patreon_badge_levels = all_award_levels_above('Patreon Badge', @reward_levels)
@gold_patreon_badge_levels = all_award_levels_above('Patreon Gold Badge', @reward_levels)

# connect to vanilla
@vanilla_db = connect_to_vanilla

# grant rewards
create_virtual_wall_post(@virtual_wall_levels, @patrons, @vanilla_db)
award_patreon_badges(@patreon_badge_levels, @patrons, @vanilla_db)
award_gold_patreon_badges(@gold_patreon_badge_levels, @patrons, @vanilla_db)