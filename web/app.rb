# frozen_string_literal: true

require "sinatra"
require "omniauth-github"
require "octokit"
require "rack/protection"
require "active_support/core_ext/object/blank"

GITHUB_KEY = ENV["GITHUB_KEY"]
GITHUB_SECRET = ENV["GITHUB_SECRET"]
SESSION_SECRET = ENV["SESSION_SECRET"]
STRAP_ISSUES_URL = ENV["STRAP_ISSUES_URL"]
STRAP_BEFORE_INSTALL = ENV["STRAP_BEFORE_INSTALL"]
CUSTOM_HOMEBREW_TAP = ENV["CUSTOM_HOMEBREW_TAP"]
CUSTOM_BREW_COMMAND = ENV["CUSTOM_BREW_COMMAND"]
OMNIAUTH_FULL_HOST = ENV["OMNIAUTH_FULL_HOST"]

# In some configurations, the full host may need to be set to something other
# than the canonical URL.
OmniAuth.config.full_host = OMNIAUTH_FULL_HOST if OMNIAUTH_FULL_HOST

set :sessions, secret: SESSION_SECRET

use OmniAuth::Builder do
  options = {
    # access is given for gh cli, packages, git client setup and repo checkouts
    scope:        "user:email, repo, workflow, write:packages, read:packages, read:org, read:discussions",
    allow_signup: false,
  }
  options[:provider_ignores_state] = true if ENV["RACK_ENV"] == "development"
  provider :github, GITHUB_KEY, GITHUB_SECRET, options
end

use Rack::Protection, use: %i[authenticity_token cookie_tossing form_token
                              remote_referrer strict_transport]

get "/auth/github/callback" do
  auth = request.env["omniauth.auth"]

  session[:auth] = {
    "info"        => auth["info"],
    "credentials" => auth["credentials"],
  }

  return_to = session.delete :return_to
  return_to = "/strap.sh" if !return_to || return_to.empty?
  redirect to return_to
end

get "/" do
  if request.scheme == "http" && ENV["RACK_ENV"] != "development"
    redirect to "https://#{request.host}#{request.fullpath}"
  end

  before_install_list_item = "<li>#{STRAP_BEFORE_INSTALL}</li>" if STRAP_BEFORE_INSTALL

  debugging_text = if STRAP_ISSUES_URL.blank?
    "try to debug it yourself"
  else
    %(file an issue at <a href="#{STRAP_ISSUES_URL}">#{STRAP_ISSUES_URL}</a>)
  end

  @title = "👢 Strap"
  @text = <<~HTML
    To Strap your system:
    <ol>
      #{before_install_list_item}
      <li>
        <form method="post" action="/auth/github">
          <input type="hidden" name="authenticity_token" value="#{request.env['rack.session']['csrf']}">
          <button type="submit" class="btn btn-outline-primary btn-sm">
            Download the <code>strap.sh</code>
          </button>
        </a>
        that's been customised for your GitHub user (or
        <a href="/strap.sh?text=1">view it</a>
        first). This will prompt for access to your email, public and private
        repositories; you'll need to provide access to any organizations whose
        repositories you need to be able to <code>git clone</code>. This is
        used to add a GitHub access token to the <code>strap.sh</code> script
        and is not otherwise used by this web application or stored
        anywhere.
      </li>

      <li>
        Run Strap in Terminal.app with <code>bash ~/Downloads/strap.sh</code>.
      </li>

      <li>
        If something failed, run Strap with more debugging output in
        Terminal.app with <code>bash ~/Downloads/strap.sh --debug</code> and
        #{debugging_text}.
      </li>

      <li>
        Delete the customised <code>strap.sh</code> (it has a GitHub token
        in it) in Terminal.app with
        <code>rm -f ~/Downloads/strap.sh</code>
      </li>

      <li>
        Install additional software with
        <code>brew install</code>.
      </li>
    </ol>
  HTML
  erb :root
end

get "/strap.sh" do
  auth = session[:auth]

  script = File.expand_path("#{File.dirname(__FILE__)}/../bin/strap.sh")
  content = IO.read(script)

  set_variables = { STRAP_ISSUES_URL: STRAP_ISSUES_URL }
  unset_variables = {}

  unset_variables[:CUSTOM_HOMEBREW_TAP] = CUSTOM_HOMEBREW_TAP if CUSTOM_HOMEBREW_TAP

  unset_variables[:CUSTOM_BREW_COMMAND] = CUSTOM_BREW_COMMAND if CUSTOM_BREW_COMMAND

  if auth
    unset_variables.merge! STRAP_GIT_NAME:     auth["info"]["name"],
                           STRAP_GIT_EMAIL:    auth["info"]["email"],
                           STRAP_GITHUB_USER:  auth["info"]["nickname"],
                           STRAP_GITHUB_TOKEN: auth["credentials"]["token"]
  end

  env_sub(content, set_variables, set: true)
  env_sub(content, unset_variables, set: false)

  # Manually set X-Frame-Options because Rack::Protection won't set it on
  # non-HTML files:
  # https://github.com/sinatra/sinatra/blob/v2.0.7/rack-protection/lib/rack/protection/frame_options.rb#L32
  headers["X-Frame-Options"] = "DENY"
  content_type = if params["text"]
    "text/plain"
  else
    "application/octet-stream"
  end
  erb content, content_type: content_type
end

private

def env_sub(content, variables, set:)
  variables.each do |key, value|
    next if value.blank?

    regex = if set
      /^#{key}='.*'$/
    else
      /^# #{key}=$/
    end
    escaped_value = value.gsub(/'/, "\\\\\\\\'")
    content.gsub!(regex, "#{key}='#{escaped_value}'")
  end
end
