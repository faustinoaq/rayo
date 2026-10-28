require "../../src/rayo/sqlite/group_commit"

db = Rayo::SQLite::Database.new(":memory:")
group = Rayo::SQLite::GroupCommit.new(db)
group.flush
db.close
