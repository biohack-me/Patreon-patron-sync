#!/usr/bin/env ruby

require_relative 'patron_functions'

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
