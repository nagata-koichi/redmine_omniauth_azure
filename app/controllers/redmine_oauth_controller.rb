require 'account_controller'
require 'json'
require 'jwt'

class RedmineOauthController < AccountController
  include Helpers::MailHelper
  include Helpers::Checker
  def oauth_azure
    if Setting.plugin_redmine_omniauth_azure['azure_oauth_authentication']
      session['back_url'] = params['back_url']
      redirect_to oauth_client.auth_code.authorize_url(:redirect_uri => oauth_azure_callback_url, :scope => scopes)
    else
      password_authentication
    end
  end

  def oauth_azure_callback
    if params['error']
      flash['error'] = l(:notice_access_denied)
      redirect_to signin_path
    else
      token = oauth_client.auth_code.get_token(params['code'], :redirect_uri => oauth_azure_callback_url, :resource => "00000002-0000-0000-c000-000000000000")
      user_info = JWT.decode(token.token, nil, false)
      logger.error user_info
      
      email = user_info.first['unique_name']

      if email
        checked_try_to_login email, user_info.first
      else
        flash['error'] = l(:notice_no_verified_email_we_could_use)
        redirect_to signin_path
      end
    end
  end

  def checked_try_to_login(email, user)
    if allowed_domain_for?(email)
      try_to_login email, user
    else
      flash['error'] = l(:notice_domain_not_allowed, :domain => parse_email(email)[:domain])
      redirect_to signin_path
    end
  end

  def try_to_login email, info
    params['back_url'] = session['back_url']
    session.delete(:back_url)

    user = User.joins(:email_addresses)
               .where('email_addresses.address' => email, 'email_addresses.is_default' => true)
               .first_or_initialize
    if user.new_record?
      # Self-registration off
      redirect_to(home_url) && return if Setting.plugin_redmine_omniauth_azure['azure_self_registration'].to_i.zero?
      # Create on the fly
      case Setting.user_format
      when :lastname_firstname,:lastnamefirstname,:lastname_comma_firstname,:lastname
        user.lastname, user.firstname = info["name"].split(' ') unless info['name'].nil?
      else
        user.firstname, user.lastname = info["name"].split(' ') unless info['name'].nil?
      end

      user.firstname ||= info["name"]
      user.lastname ||= info["name"]
      user.mail = email
      user.login = info['login']
      user.login ||= email
      user.random_password
      user.register

      case Setting.plugin_redmine_omniauth_azure['azure_self_registration']
      when '1'
        register_by_email_activation(user) do
          onthefly_creation_failed(user)
        end
      when '3'
        register_automatically(user) do
          onthefly_creation_failed(user)
        end
      else
        register_manually_by_administrator(user) do
          onthefly_creation_failed(user)
        end
      end
    else
      # Existing record
      if user.active?
        successful_authentication(user)
      else
        account_pending(user)
      end
    end
  end

  def oauth_client
    @client ||= OAuth2::Client.new(settings['client_id'], settings['client_secret'],
      :site => 'https://login.windows.net',
      :authorize_url => '/' + settings['tenant_id'] + '/oauth2/authorize',
      :token_url => '/' + settings['tenant_id'] + '/oauth2/token')
  end

  def settings
    @settings ||= Setting.plugin_redmine_omniauth_azure
  end

  def scopes
    'user:email'
  end
end
