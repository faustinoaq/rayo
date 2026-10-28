module Rayo::PG
  lib LibPoll
    struct Event
      fd : Int32
      events : Int16
      revents : Int16
    end

    fun poll(events : Event*, count : LibC::ULong, timeout : Int32) : Int32
  end
end
