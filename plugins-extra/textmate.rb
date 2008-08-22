#
# TextMate related stuff.
#

require 'net/http'
require 'set'
require 'yaml'
require "cgi"

# ===============================
# = To facilitate local testing =
# ===============================

require 'async' unless $0 == __FILE__

class Async
  def Async.run(irc)
    yield
  end
end if $0 == __FILE__

class PluginBase
  def PluginBase.help(cmd, text)
    # STDERR << "Help registered for #{cmd}: #{text}.\n"
  end
end if $0 == __FILE__

# ===============================

module TMHelper
  BUNDLE_SOURCES = {
    :main   => "http://macromates.com/svn/Bundles/trunk/Bundles/",
    :review => "http://macromates.com/svn/Bundles/trunk/Review/Bundles/",
    :github => 'http://github.com/api/v1/yaml/search/tmbundle'
  }

  module_function

  def phrase_to_keywords(phrase)
    phrase.gsub(/\b(\w+)s\b/, '\1').downcase.split(/\W/).to_set
  end

  # titles is array of hashes with :link and :title keys
  def find_title_in_titles(irc, title, titles)
    keywords = phrase_to_keywords(title)
    len      = keywords.length.to_f

    matches  = titles.map do |e|
      title_keywords = phrase_to_keywords(e[:title])
      if keywords.subset? title_keywords
        { :rank => len / title_keywords.length, :link  => e[:link] }
      else
        nil
      end
    end.compact.sort { |a, b| b[:rank] <=> a[:rank] }

    case matches.size
      when 0:     irc.reply "No matches found for ‘#{title}’."
      when 1:     irc.respond matches.first[:link]
      when 2..3:  matches.each { |e| irc.respond e[:link] }
      else
        irc.respond "Results 1-3 of #{matches.size} for ‘#{title}’."
        matches[0..2].each { |e| irc.respond e[:link] }
    end
  end

  def call_with_body(irc, url)
    return unless url =~ %r{http://([^/]+)(.+)}
    host, path = $1, $2

    Async.run(irc) do
      Net::HTTP.start(host) do |http|
        re = http.get(path,  { 'User-Agent' => 'CyBrowser/1.1 (IRC bot: http://wiki.macromates.com/Cybot/)' })
        if re.code == '200'
          yield re.body
        else
          irc.reply "#{re.code} #{re.message} for #{url}"
        end
      end
    end
  end

  def find_bundle(irc, keyword)
    # subversion
    [:main, :review].each do |src|
      call_with_body(irc, BUNDLE_SOURCES[src]) do |body|
        next unless bundles = body.scan(%r{<li>\s*<a href=['"](.*?)['"]>.*?</a>})

        if found = bundles.flatten.find { |e| e =~ /#{keyword}.*?\.tmbundle/i }
          return {'name' => CGI.unescape(found[/(.+)\.tmbundle/, 1].to_s), 'url' => "#{BUNDLE_SOURCES[src]}#{found}"}
        end
      end
    end

    # github
    call_with_body(irc, 'http://github.com/api/v1/yaml/search/tmbundle') do |body|
      return unless repos = YAML.load(body)
      found = repos['repositories'].find { |result| result['name'].match(/#{keyword}/i) }
      return found if found
    end

    # try google
    keyword = "#{keyword} textmate bundle"

    call_with_body(irc, "http://www.google.com/search?ie=utf8&oe=utf8&q=#{CGI.escape keyword}") do |body|
      # the google search code should be moved some place it can be shared among plugins.
      return unless body =~ /<a href="([^"]+)" class=l>(.+?)<\/a>/
      link = $1
      desc = $2.gsub('<b>', "\x02").gsub('</b>', "\x0f")
      desc.gsub!(/<.*?>/, '')
      return {'name' => CGI.unescapeHTML(desc), 'url' => link }
    end

  rescue => e
    $log.puts "Error while searching for bundle: #{e.message}"
    $log.puts e.backtrace.join("\n")
  end
end

class Textmate < PluginBase
  def cmd_doc(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: doc <search string or regex>'
    else
      TMHelper.call_with_body(irc, 'http://manual.macromates.com/en/') do |body|
        toc = body.scan(%r{<li>\s*([\d.]+)\s*<a href=['"](.*?)['"]>(.*?)</a>})
        entries = toc.map do |e|
          { :link  => 'http://manual.macromates.com/en/' + e[1].gsub(/^([^#]+)#\1$/, '\1'),
            :title => e[2].gsub(%r{</?\w+>}, '')
          }
        end
        TMHelper.find_title_in_titles(irc, line, entries)
      end
    end
  end
  help :doc, 'Searches the TextMate manual for the given string or regex.'

  def cmd_faq(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: faq <search keyword(s)>'
    else
      TMHelper.call_with_body(irc, 'http://wiki.macromates.com/Main/FAQ') do |body|
        toc = body.scan(%r{<a name=["'](.*?)["'][^>]*>.*?Keywords:(.*?)</span>})
        entries = toc.map do |e|
          { :link  => 'http://wiki.macromates.com/Main/FAQ#' + e[0],
            :title => e[1]
          }
        end
        TMHelper.find_title_in_titles(irc, line, entries)
      end
    end
  end
  help :faq, 'Searches the TextMate FAQ for the given keyword(s).'

  def cmd_howto(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: howto <search keyword(s)>'
    else
      TMHelper.call_with_body(irc, 'http://wiki.macromates.com/Main/HowTo/') do |body|
        toc = body.scan(%r{<a .*\bhref=['"](http://wiki.macromates.com/HowTo/(?!HomePage|RecentChanges).+)['"][^>]*>(.*?)</a>})
        entries = toc.map do |e|
          { :link  => e[0],
            :title => e[1].gsub(/([A-Z]+)([A-Z][a-z])/,'\1 \2').gsub(/([a-z\d])([A-Z])/,'\1 \2')
          }
        end
        TMHelper.find_title_in_titles(irc, line, entries)
      end
    end
  end
  help :howto, 'Searches http://wiki.macromates.com/Main/HowTo/ for the given keyword(s).'

  def cmd_ts(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: ts <search keyword(s)>'
    else
      TMHelper.call_with_body(irc, 'http://wiki.macromates.com/Troubleshooting/HomePage/') do |body|
        toc = body.scan(%r{<a .*\bhref=['"](http://wiki.macromates.com/Troubleshooting/(?!HomePage|RecentChanges).+)['"][^>]*>(.*?)</a>})
        entries = toc.map do |e|
          { :link  => e[0],
            :title => e[1].gsub(/([A-Z]+)([A-Z][a-z])/,'\1 \2').gsub(/([a-z\d])([A-Z])/,'\1 \2')
          }
        end
        TMHelper.find_title_in_titles(irc, line, entries)
      end
    end
  end
  help :ts, 'Searches http://wiki.macromates.com/Troubleshooting/HomePage/ for the given keyword(s).'

  def cmd_calc(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: calc <expression>. The expression must be in the bc language.'
    else
      Async.run(irc) do
        result = nil
        IO.popen('bc -l 2>&1', 'r+') do |f|
          f.puts line
          result = f.gets.strip
        end
        irc.reply result
      end
    end
  end
  help :calc, "Calculates the expression given and returns the answer. The expression must be in the bc language."

  def cmd_bundle(irc, line)
    return irc.reply('USAGE: bundle <search keyword(s)>') if line.to_s.empty?
    if bundle = TMHelper.find_bundle(irc, line)
      irc.reply "#{bundle['url']} (#{bundle['name']})"
    else
      irc.reply "Nothing found for #{line.inspect}."
    end
  end
  help :bundle, "Searches for a bundle in the Subversion repository, GitHub and Google."

end

if $0 == __FILE__
  class IRC
    class << self
      def reply(msg)
        STDERR << "→ " << msg << "\n"
      end
      alias respond reply
    end
  end

  tm = Textmate.new

  tm.cmd_calc(IRC, '4 + 3')
  tm.cmd_doc(IRC, 'language grammar')
  tm.cmd_faq(IRC, 'remote')
  tm.cmd_howto(IRC, 'tidy')
  tm.cmd_ts(IRC, '101')

  tm.cmd_doc(IRC, 'url')
  tm.cmd_doc(IRC, 'how')
  tm.cmd_doc(IRC, 'customizing')
  tm.cmd_doc(IRC, 'tabs')
  tm.cmd_doc(IRC, 'TeXt')

  tm.cmd_bundle(IRC, "haml")
  tm.cmd_bundle(IRC, "Maude")
  tm.cmd_bundle(IRC, 'datamapper')
  tm.cmd_bundle(IRC, 'foobar')

end
