# biohack.me patreon sync

Connects to the [Patreon API](https://github.com/Patreon/patreon-ruby) to get current patrons to grant forum rewards by directly manipulating the [Vanilla](https://github.com/biohack-me/vanilla) (and [YAGA application](https://github.com/biohack-me/Application-Yaga)) database.


## Care and feeding

Mostly, just updating gems occassionally, unless a change to the format of the output is desired, or if the patreon patron tiers change at all.

It is worth noting that the patreon levels that this app reads need to be hard coded into `patron_sync.rb`, so if these change at all (including just text changes in the level titles), that file will also need to be updated.

The levels currently looked for are:
- 'Patreon Virtual Wall'
- 'Patreon Badge'
- 'Patreon Gold Badge'


## Development

You will need a local copy of our vanilla database and our patreon API key.

Copy the provided `credentials.rb.example` file to `credentials.rb` and set the database connection info and patreon access token.

Then, open an `irb` console to test individual functions provided in `patron_functions.rb` (remember to `require_relative 'patron_functions'`), or, run `./patron_sync.rb` to test the entire process and update your local vanilla database.


## Deploying

After pushing any local changes to github, go to the project directory on the biohack.me server and do a `git pull` and `bundle install`. There is a cron job set up on the server to run `patron_sync.rb` on the first of every month.