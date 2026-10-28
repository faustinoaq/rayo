require "spec"
require "../src/rayo"

# Exec a fresh runtime: a raw-fork child cannot continue the default MT runtime.
# /proc keeps this exact executable even if a concurrent build replaces its path.
def start_fixture(name : String, env : Hash(String, String)) : Process
  env["RAYO_SPEC_FIXTURE"] = name
  Process.new("/proc/#{Process.pid}/exe", env: env, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
end

# GC.stats is process-wide. Only the single-thread runtime excludes SYSMON noise.
# Both CI runtimes run these checks; the request-only configuration requires zero.
def assert_no_request_allocations(allocated : UInt64) : Nil
  {% if flag?(:without_mt) %}
    allocated.should eq(0)
  {% else %}
    allocated.should be < 1024
  {% end %}
end
