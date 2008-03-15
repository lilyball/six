#
# Goners plugin for CyBot.
# By Henrik Nyh <http://henrik.nyh.se> 2007-07-18.
#
# Notices messages like "bb30", "bb2-3h", "shopping - bb 1 hour and 30 minutes" and
# informs people that address the absentee that they're gone and – if it could
# be detected – for how long. Resets absentee status on join or on saying something.

### TODO
# + Drop someone from all informees lists if they disconnect?
# + Track name changes for absentees?
# + Something like "bot_name: back" to bypass grace period

class Numeric
  INFINITY = 1.0/0
  def second() self end
  alias_method :seconds, :second
  def minute() 60*seconds end
  alias_method :minutes, :minute
  def hour() 60*minutes end
  alias_method :hours, :hour
  def day() 24*hours end
  alias_method :days, :day
  def week() 7*days end
  alias_method :weeks, :week
  def month() 31*days end
  alias_method :months, :month
  def year() 365.25*days end
  alias_method :years, :year
end


class Goner < Struct.new(:nick, :channel, :message)
  require "set"

  attr_reader   :gone_at, :back_at
  attr_accessor :informees
  # Class level accessor plus an instance level reader
  class << self; attr_accessor :plugin end
  def plugin() self.class.plugin end
  
  def initialize(*args)
    super
    @gone_at   = Time.now
    @back_at   = make_back_at!  # calculate once and cache
    @informees = Set.new
    self.message.sub!(/^\001ACTION (.*)\001$/) { "/me #{$1}" }  # Make "/me" messages presentable
  end
    
  def back_in_seconds
    back_at ? (back_at - Time.now).round : Numeric::INFINITY
  end
  # String representation of when the person is expected back, or nil if this is unknown.
  def back_in_words
    return nil unless back_at                # No time stored, e.g. "bb soon"
    return "by now" if back_in_seconds <= 0  # Due back already
    return "in " + plugin.seconds_to_s_fuzzy(back_in_seconds)
  end
  # Human-readable message like "expected back in 1 minute" or "away"
  def status
    back_in = self.back_in_words
    status = back_in ? "expected back #{back_in}" : "away"
  end
  
  def stated_gone_for_in_seconds
    back_at ? (back_at - gone_at).round : Numeric::INFINITY
  end
  def gone_for_in_seconds
    (Time.now - gone_at).round
  end
  def gone_for_in_words
    plugin.seconds_to_s_exact(Time.now - gone_at)
  end
  
  def has_informed?(sender_key)
    informees.include?(sender_key)
  end
  def has_informed!(sender_key)
    informees << sender_key
  end
  
  # Output will not be interpreted as the user returning during the grace period
  def state_of_grace?
    grace_period = (stated_gone_for_in_seconds <= 1.minute) ? 15.seconds : 1.minute
    gone_for_in_seconds <= grace_period
  end
  
  # Used to get a channel object for notices, that have an empty irc.channel.
  # Compare a stored channel name with the user's list of channels.
  def channel(irc)
    irc.from.server.channels[super().downcase]
  end
  
private

  # When will someone be back, based on a message string?
  # Returns nil if unparsable; otherwise a Time object.
  def make_back_at!
    if match = message.match(/#{Goners::PREFIX}#{Goners::TIME}/)
      y, mon, w, d, h, min = match.captures.map {|m| m.to_f }
      Time.now + y.years + mon.months + w.weeks + d.days + h.hours + min.minutes
    end
  end
  
end

class PluginBase; end  # So we can run this file directly (for unit tests)
class Goners < PluginBase
  
  begin # configuration (for folding)

    $KCODE = 'u'  # Enable UTF-8 in regexps
    FILE   = "goners.yml"
    ITALIC = "\x16"  # http://www.visualirc.net/tech-attrs.php

    PREFIX = /
      (?:
        (?:                              # "bb" could be…
          ^|                               # initial, like "bb soon, fool";
          [.,:;—–-]\s*|                    # after punctuation, like "thanks - bb soon";
          \bwill\s+                        # after "will", like "I will bb soon";
        )bb
          (?=                            # and then followed by…
            $|                             # the end of string;
            (?:l|l8r)\b|                   # "l" ("bbl") or "l8r" ("bbl8r")
            [^a-z]                         # but no other letters (not "bbedit")
          )
        |
          [^\w"'“]                       # Any other "bb" must follow a non-word char (but not be quoted: 'I did "bb2h"')
          bb(?=\s*\d)                    # and be followed by numbers (not "I like the bb command").
      )                   
      (?:\s+in)?                         # "bb in" is fine;
      (?:\s+about|\s*~)?                 # "bb in about" or "bb~" too.
      (?:\s*\d+\s*[—–-]{1,2}\s*)?        # Consume the beginning of ranges, e.g. "bb 12 -- 34min" => 0h 34m
      \s*
    /ix

    # Generates a regexp matching e.g. "2 hours, and" from input like '/h|hours?/'
    regexp_for_unit = lambda do |re|
      delimiter = /,?(?:\s+and\s+|\s*)/i
      /(\d+(?:\.\d+)?)\s*#{re}#{delimiter}/
    end
    TIME = /
      (?=\d)                                        # Require digit lest we match the empty string (since all units are optional)
      #{regexp_for_unit.call( /years?|yrs?|y/ )}?
      #{regexp_for_unit.call( /months?|mons?/ )}?
      #{regexp_for_unit.call( /weeks?|wks?|w/ )}?
      #{regexp_for_unit.call( /days?|d/ )}?
      #{regexp_for_unit.call( /hours?|hrs?|h/ )}?
      (?!\d+:\d)                                    # Prevents catching times like "bb 12:45" that should remain unparsed
      (\d+(?:\.\d+)?)?                              # Catch-all for any number, assumed to be minutes: for "bb 20" etc
    /ix

  end # configuration


  begin # plugin hooks (for folding)

    def initialize(*args)
      @brief_help = 'Notices e.g. "bb30" and informs about absence of addressed users'
      Goner.plugin = self  # Give Goner class a reference to the plugin instance, to use date formatters - bit ugly :/
      super(*args)
    end

    # Called for all incoming channel messages
    def hook_privmsg_chan(irc, message)
      if message =~ PREFIX  # Go absent
        gone(irc, message)
      else                  # When someone speaks, they're no longer gone
        ungone(irc)
      end
      # Addressing an absentee
      tell(irc, $1) if message =~ @absentee_regexp
    end
  
    # When someone joins, they're no longer gone
    def hook_join_chan(irc)
      ungone(irc)
    end

    # When someone changes back to their nick, they're no longer gone
    def hook_command_serv(irc, handled, cmd, *args)
      return unless cmd == 'NICK'
      ungone(irc, args.first)  # Pass along new nick
    end
  
    # Persist data

    def load
      @goners = YAML.load_file(file_name(FILE)) rescue {}
      @goners = {} unless @goners.is_a?(Hash)
      recompile_regexp!
    end

    def save
      begin
        open_file(FILE, 'w') do |f|
          f.puts "# CyBot Goners plugin"
          YAML.dump(@goners, f)
          f.puts
        end
        return true
      rescue Exception => e
        $log.puts e.message
        $log.puts e.backtrace.join("\n")
      end
      false
    end
  
  end # plugin hooks


protected

  # Used in gone and ungone for e.g. "See you in 2 hours, foo!" and "Welcome back, foo!"
  # Mainly to appease subtleGradient, since he keeps running into plugin edge cases :p
  def special_treatment(user)
    title = case user
            when /subtleGradient/i: 'darling'
            when /Soryu/i:          'Stan'
            end
    title ? ", #{title}" : nil
  end

  def ungone(irc, new_nick=false)
    user = new_nick || irc.from.nick
    key = IRC::Address.normalize(user)
    goner = @goners[key]
    
    if goner && !goner.state_of_grace?
      @goners.delete(key)
      recompile_regexp!
      title = special_treatment(user)
      goner.channel(irc).privmsg "#{user}: Welcome back#{ title }!"
    end
  end

  def gone(irc, message)
    key, user = irc.from.nnick, irc.from.nick
    channel = irc.channel.name  # Stored because nick change notifications are channel-less
    goner = Goner.new(user, channel, message)
    @goners[key] = goner
    recompile_regexp!
    back_in = goner.back_in_words
    title = special_treatment(user)
    irc.reply "See you#{" #{back_in}" if back_in}#{ title }!"
  end

  def tell(irc, goner)
    goner_key, sender_key = IRC::Address.normalize(goner), irc.from.nnick
    goner = @goners[goner_key]
    unless goner.has_informed?(sender_key)
      irc.reply "#{goner.nick} is #{goner.status} – #{goner.gone_for_in_words} ago, they said: #{ITALIC + goner.message + ITALIC}!"
      goner.has_informed!(sender_key)
    end
  end

  def recompile_regexp!
    if @goners.empty?
      @absentee_regexp = nil
    else
      @absentee_regexp = Regexp.new('^(' + @goners.keys.map { |key| Regexp.escape(key) }.join("|") + ')[,:>]', "i")
    end
  end

end


# Unit tests (could do with better coverage, refactoring)

if __FILE__ == $0
  require "test/unit"
  
  # For testing purposes, add a gone_at setter and a constructor that takes message and departure time.
  class Goner
    def gone_at=(time)
      instance_eval { @gone_at = time }
    end
    def self.test(message, at=Time.now)
      instance = new("tester", "##textmate", message)
      instance.gone_at = at
      instance
    end
  end
  
  class GonersPluginTest < Test::Unit::TestCase
    UNPARSABLE = Numeric::INFINITY
    
    # Just for documentation
    def test_time_units
      assert_equal 31.days, 1.month
      assert_equal (365.25).days, 1.year
    end
    
    def test_prefixes
      pass = [
        "bb", "bb soon", "bb soon, fool",
        "hi. bb soon", "hi, bb soon", "hi: bb soon", "hi; bb soon", "hi - bb soon", "hi — bb soon", "hi.bb soon",
        "will bb", "i will bb soon",
        "bbl", "bbl8r",
        "I'm bound to bb 123",
        "bb123",
        "bb in 123", "bb in about 123", "bb ~123", "bb~123",
        "bb 123-456", "bb 123–456"
      ]
      fail = [
        "", "x",
        "bbedit", "i love bbedit", "i will bbedit soon",
        "i tried 'bb soon'", 'i tried "bb soon"', 'i tried “bb soon"', "i'm bound to bb soon"
      ]
      pass.each do |message|
        assert message =~ Goners::PREFIX
      end
      fail.each do |message|
        assert message !~ Goners::PREFIX
      end
    end

    def test_time_parsing
      expected_mappings = {
        "bbedit" => false,
        "bb soon" => UNPARSABLE,
        ["bb1", "bb1m", "bb 1 minute"] => 1.minute,   "bb2 minutes" => 2.minutes,
        ["bb1h", "bb 1 hour"] => 1.hour,              "bb2 hours" => 2.hours,
        ["bb1d", "bb 1 day"] => 1.day,                "bb2 days" => 2.days,
        ["bb1w", "bb1wk", "bb 1 week"] => 1.week,     ["bb2wks", "bb2 weeks"] => 2.weeks,
        ["bb1mon", "bb 1 month"] => 1.month,          ["bb2mons", "bb 2months"] => 2.months,
        ["bb1y", "bb 1 yr", "bb 1 year"] => 1.year,   ["bb2 yrs", "bb 2years"] => 2.years,
        "bb123" => 2.hours + 3.minutes,
        ["bb in 1 year, 2 months, 3 weeks, 4 hours and 5 minutes", "bb 1y2mon3w4h5m"] => 1.year + 2.months + 3.weeks + 4.hours + 5.minutes
      }
      expected_mappings.each do |(messages, seconds)|
        messages.each do |message|
          goner = (message =~ Goners::PREFIX ? Goner.test(message) : false)
          if goner
            assert_equal seconds, goner.back_in_seconds, "Parsing '#{message}'"
          else
            assert_equal false, seconds, "Parsing '#{message}'"
          end
        end
      end
    end
    
  end
end
