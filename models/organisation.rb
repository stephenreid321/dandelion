class Organisation
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  include OrganisationFields
  include OrganisationAssociations
  include OrganisationAccounting
  include OrganisationAccessControl
  include OrganisationMonthlyDonations
  include OrganisationEvm
  include OrganisationValidation
  include Geocoded
  include EvmTransactions
  include StripeWebhooks
  include ImportFromCsv

  def self.fs(slug)
    find_by(slug: slug)
  end

  def self.spring_clean
    fields = %i[image_uid]
    ignore = %i[organisationships notifications_as_notifiable]
    Organisation.all.each do |organisation|
      next unless Organisation.reflect_on_all_associations(:has_many).all? do |assoc|
        organisation.send(assoc.name).count == 0 || ignore.include?(assoc.name)
      end && fields.all? { |f| organisation.send(f).blank? } && organisation.created_at < 1.month.ago

      puts organisation.name
      organisation.destroy
    end
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def calculate_tokens
    Order.and(:event_id.in => events.pluck(:id), :value.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |o| Math.sqrt(Money.new(o.value * 100, o.currency).exchange_to('GBP').cents) } +
      organisation_contributions.and(:amount.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |p| Math.sqrt(Money.new(p.amount * 100, p.currency).exchange_to('GBP').cents) }
  end

  def banned_emails_a
    banned_emails ? banned_emails.split("\n").map(&:strip) : []
  end

  def payment_method?
    stripe_connect_json || stripe_pk || coinbase_api_key || evm_address || oc_slug
  end

  after_create do
    notifications_as_notifiable.create! circle: account, type: 'created_organisation'

    organisationships.create account: account, admin: true, receive_feedback: true
    if (dandelion = Organisation.find_by(slug: 'dandelion'))
      dandelion.organisationships.create account: account
    end
  end

  def ticket_email_greeting_default
    '<p>Hi [firstname],</p>
<p>Thanks for booking onto [event_name], [event_when] [at_event_location_if_not_online]. Your [tickets_are] attached.</p>'
  end

  def recording_email_greeting_default
    '<p>Hi [firstname],</p>
<p>Thanks for purchasing the recording of [event_name], [event_when] [at_event_location_if_not_online].</p>'
  end

  def feedback_email_body_default
    '<p>Hi [firstname],</p>
<p>Thanks for attending [event_name].</p>
<p>Would you take a minute to <a href="[feedback_url]">visit this page and give us feedback on the event</a>, so that we can keep improving?</p>
<p>With thanks,<br>[organisation_name]</p>'
  end

  def donations_to_dandelion?
    stripe_connect_json && !paid_up
  end

  def stripe_user_id
    return unless stripe_connect_json

    JSON.parse(stripe_connect_json)['stripe_user_id']
  end

  def stripe_account_name
    return unless stripe_account_json

    j = JSON.parse(stripe_account_json)
    j.dig('business_profile', 'name') ||
      j.dig('settings', 'dashboard', 'display_name') ||
      j['display_name']
  end

  def send_followers_csv(account)
    csv = CSV.generate do |csv|
      csv << %w[name firstname lastname email unsubscribed created_at monthly_donation_method monthly_donation_amount monthly_donation_currency monthly_donation_start_date]
      organisationships.each do |organisationship|
        csv << [
          organisationship.account.name,
          organisationship.account.firstname,
          organisationship.account.lastname,
          Organisation.admin?(self, account) ? organisationship.account.email : '',
          (1 if organisationship.unsubscribed),
          organisationship.created_at.to_fs(:db_local),
          organisationship.monthly_donation_method,
          organisationship.monthly_donation_amount,
          organisationship.monthly_donation_currency,
          organisationship.monthly_donation_start_date
        ]
      end
    end

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    content = ERB.new(File.read(Padrino.root('app/views/emails/csv.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject 'Dandelion CSV export'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    file = Tempfile.new
    file.write(csv)
    file.rewind
    batch_message.add_attachment(file.path, 'followers.csv')

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    file.close
    file.unlink
  end
  handle_asynchronously :send_followers_csv
end
