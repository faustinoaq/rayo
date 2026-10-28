require "./spec_helper"

describe "standalone SQLite group commit" do
  it "loads its loop dependencies without requiring rayo first" do
    errors = IO::Memory.new
    status = Process.run("crystal", ["build", "--no-codegen", File.join(__DIR__, "fixtures/sqlite_group_compile.cr")], output: Process::Redirect::Close, error: errors)
    fail errors.to_s unless status.success?
  end
end
