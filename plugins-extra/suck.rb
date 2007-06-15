#
# You suck plugin for CyBot.
# Alexander H. Færøy <eroyf@gentoo.org>
#

class Suck < PluginBase
	def initialize(*args)
		@brief_help = 'Tells a user what we think about him'
		super(*args)
	end

	def parse(irc, string)
		case string
			when "you suck" then 
				irc.reply "yeah, and you seem to like it..."
		end
	end

	def hook_privmsg_chan(irc, msg)
		regexp = Regexp.new "^\s*#{irc.server.nick}[,:]\s(.*)"

		if msg =~ regexp
			parse(irc, "#{$1}")
		end
	end
end
