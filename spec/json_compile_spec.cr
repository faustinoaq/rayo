require "./spec_helper"

describe "JSON type checking" do
  it "rejects unsupported fields with an actionable compile error" do
    errors = IO::Memory.new
    status = Process.run("crystal", ["build", "--no-codegen", File.join(__DIR__, "fixtures/unsupported_json.cr")], output: Process::Redirect::Close, error: errors)
    status.success?.should be_false
    errors.to_s.should contain("Unsupported JSON value type Pointer(Int32); implement to_json(Rayo::JSON::Writer)")
  end
end
