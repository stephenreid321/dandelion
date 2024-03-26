class Order
  class OrderNotFound < StandardError; end

  class Restored < StandardError; end

  class PaymentMethodNotFound < StandardError; end

  class NoTickets < StandardError; end
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paranoia

  belongs_to :event, index: true, optional: true
  belongs_to :account, class_name: 'Account', inverse_of: :orders, index: true, optional: true
  belongs_to :revenue_sharer, class_name: 'Account', inverse_of: :orders_as_revenue_sharer, index: true, optional: true
  belongs_to :affiliate, polymorphic: true, index: true, optional: true
  belongs_to :discount_code, optional: true # removed index

  field :value, type: Float
  field :original_description, type: String
  field :percentage_discount, type: Integer
  field :percentage_discount_monthly_donor, type: Integer
  field :session_id, type: String
  field :payment_intent, type: String
  field :transfer_id, type: String
  field :coinbase_checkout_id, type: String
  field :evm_secret, type: String
  field :evm_value, type: BigDecimal
  field :oc_secret, type: String
  field :payment_completed, type: Boolean
  field :application_fee_amount, type: Float
  field :currency, type: String
  field :opt_in_organisation, type: Boolean
  field :opt_in_facilitator, type: Boolean
  field :credit_applied, type: Float
  field :organisation_revenue_share, type: Float
  field :hear_about, type: String
  field :http_referrer, type: String
  field :message_ids, type: String
  field :answers, type: Array

  field :gc_plan_id, type: String
  field :gc_given_name, type: String
  field :gc_family_name, type: String
  field :gc_address_line1, type: String
  field :gc_city, type: String
  field :gc_postal_code, type: String
  field :gc_branch_code, type: String
  field :gc_account_number, type: String
  field :gc_success, type: Boolean

  attr_accessor :prevent_refund, :cohost

  def self.admin_fields
    {
      value: :number,
      currency: :text,
      credit_applied: :number,
      percentage_discount: :number,
      percentage_discount_monthly_donor: :number,
      application_fee_amount: :number,
      organisation_revenue_share: :number,
      http_referrer: :text,
      session_id: :text,
      payment_intent: :text,
      transfer_id: :text,
      coinbase_checkout_id: :text,
      evm_secret: :text,
      evm_value: :number,
      oc_secret: :text,
      payment_completed: :check_box,
      opt_in_organisation: :check_box,
      opt_in_facilitator: :check_box,
      message_ids: :text_area,
      answers: { type: :text_area, disabled: true },
      event_id: :lookup,
      account_id: :lookup,
      discount_code_id: :lookup,
      original_description: :text_area,
      gc_plan_id: :text,
      gc_given_name: :text,
      gc_family_name: :text,
      gc_address_line1: :text,
      gc_city: :text,
      gc_postal_code: :text,
      gc_branch_code: :text,
      gc_account_number: :text,
      gc_success: :check_box,
      tickets: :collection,
      donations: :collection
    }
  end

  after_save do
    event.clear_cache if event
  end
  after_destroy do
    event.clear_cache if event
  end

  validates_uniqueness_of :session_id, :payment_intent, :coinbase_checkout_id, allow_nil: true
  validates_uniqueness_of :evm_secret, scope: :evm_value, allow_nil: true

  def self.currencies
    CURRENCY_OPTIONS
  end

  has_many :tickets, dependent: :destroy
  has_many :donations, dependent: :destroy

  has_many :notifications, as: :notifiable, dependent: :destroy

  def circle
    account
  end

  def self.email_viewer?(order, account)
    account && order && (Event.email_viewer?(order.event, account) || (order.opt_in_facilitator && Event.admin?(order.event, account)))
  end

  def payment_completed!
    set(payment_completed: true)
    tickets.set(payment_completed: true)
    donations.set(payment_completed: true)
    event.clear_cache if event
  end

  def restore_and_complete
    tickets.deleted.each(&:restore)
    donations.deleted.each(&:restore)
    restore
    payment_completed!
    update_destination_payment
    send_tickets
    create_order_notification
  end

  def incomplete?
    !payment_completed
  end

  def complete?
    payment_completed
  end

  def self.incomplete
    self.and(:payment_completed.ne => true)
  end

  def self.complete
    self.and(payment_completed: true)
  end

  def description_elements
    d = []
    TicketType.and(:id.in => tickets.pluck(:ticket_type_id)).each do |ticket_type|
      d << "#{"#{ticket_type.name} " if ticket_type}#{Money.new(ticket_type.price * 100, currency).format(no_cents_if_whole: true) if ticket_type.price}x#{tickets.and(ticket_type: ticket_type).count}"
    end

    d << "#{percentage_discount}% discount" if percentage_discount
    d << "#{percentage_discount_monthly_donor}% discount" if percentage_discount_monthly_donor

    donations.each do |donation|
      d << "#{Money.new(donation.amount * 100, currency).format(no_cents_if_whole: true)} donation"
    end

    d << "#{Money.new(credit_applied * 100, currency).format(no_cents_if_whole: true)} credit applied" if credit_applied

    d
  end

  def description
    d = description_elements
    "#{event.name}, #{event.when_details(account.try(:time_zone))}#{" at #{event.location}" if event.location != 'Online'}#{": #{d.join(', ')}" unless d.empty?}"
  end

  def evm_offset
    evm_secret.to_d / 1e6
  end

  before_validation do
    self.evm_value = value.to_d + evm_offset if evm_secret && !evm_value
    self.discount_code = nil if discount_code && !discount_code.applies_to?(event)
    self.percentage_discount = discount_code.percentage_discount if discount_code
    if !percentage_discount && !event.no_discounts && (organisationship_for_discount = event.organisationship_for_discount(account))
      self.percentage_discount_monthly_donor = organisationship_for_discount.monthly_donor_discount
    end
    if cohost && !affiliate_type && !affiliate_id
      self.affiliate_type = 'Organisation'
      self.affiliate_id = Organisation.find_by(slug: cohost).try(:id)
    end
    if affiliate_type && %w[Account Organisation].include?(affiliate_type)
      unless affiliate_type.constantize.find(affiliate_id)
        self.affiliate_id = nil
        self.affiliate_type = nil
      end
    else
      self.affiliate_id = nil
      self.affiliate_type = nil
    end
  end

  def ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.price || 0) * 100, ticket.currency) }
    r
  end

  def discounted_ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100, ticket.currency) }
    r
  end

  def organisation_discounted_ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100 * (ticket.organisation_revenue_share || 1), ticket.currency) }
    r
  end

  def donation_revenue
    r = Money.new(0, currency)
    donations.each { |donation| r += Money.new((donation.amount || 0) * 100, donation.currency) }
    r
  end

  def apply_credit
    return unless (organisationship = event.organisation.organisationships.find_by(account: account))

    begin
      credit_balance = organisationship.credit_balance.exchange_to(currency)
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      return
    end
    return unless credit_balance.positive?

    if credit_balance >= (discounted_ticket_revenue + donation_revenue)
      update_attribute(:credit_applied, (discounted_ticket_revenue + donation_revenue).cents.to_f / 100)
    elsif credit_balance < (discounted_ticket_revenue + donation_revenue)
      update_attribute(:credit_applied, credit_balance.cents.to_f / 100)
    end
  end

  after_create do
    if opt_in_organisation
      event.organisation_and_cohosts.each do |organisation|
        organisation.organisationships.create account: account
      end
      event.activity.activityships.create account: account if event.activity && event.activity.privacy == 'open'
      event.local_group.local_groupships.create account: account if event.local_group
    end
    sign_up_to_gocardless if gc_plan_id
  end

  def update_destination_payment
    return unless application_fee_amount

    begin
      Stripe.api_key = event.organisation.stripe_sk
      Stripe.api_version = '2020-08-27'
      pi = Stripe::PaymentIntent.retrieve payment_intent
      transfer = Stripe::Transfer.retrieve pi.charges.first.transfer

      Stripe.api_key = JSON.parse(event.revenue_sharer_organisationship.stripe_connect_json)['access_token']
      Stripe.api_version = '2020-08-27'
      destination_payment = Stripe::Charge.retrieve transfer.destination_payment
      Stripe::Charge.update(destination_payment.id, {
                              description: "#{account.name}: #{description}",
                              metadata: metadata
                            })
    rescue StandardError => e
      Airbrake.notify(e)
    end
  end

  after_destroy :refund
  def refund
    return unless event.refund_deleted_orders && !prevent_refund && event.organisation && event.organisation.stripe_sk && value && value.positive? && payment_completed && payment_intent

    begin
      Stripe.api_key = event.organisation.stripe_sk
      Stripe.api_version = '2020-08-27'
      pi = Stripe::PaymentIntent.retrieve payment_intent
      if event.revenue_sharer_organisationship
        Stripe::Refund.create(
          charge: pi.charges.first.id,
          refund_application_fee: true,
          reverse_transfer: true
        )
      else
        Stripe::Refund.create(charge: pi.charges.first.id)
      end
    rescue Stripe::InvalidRequestError
      true
    end
  end

  def metadata
    order = self
    {
      de_event_id: event.id,
      de_order_id: order.id,
      de_account_id: order.account_id,
      de_donation_revenue: order.donation_revenue,
      de_ticket_revenue: order.ticket_revenue,
      de_discounted_ticket_revenue: order.discounted_ticket_revenue,
      de_percentage_discount: order.percentage_discount,
      de_percentage_discount_monthly_donor: order.percentage_discount_monthly_donor,
      de_credit_applied: order.credit_applied
    }
  end

  def total
    ((discounted_ticket_revenue + donation_revenue).cents.to_f / 100) - (credit_applied || 0)
  end

  def calculate_application_fee_amount
    (((discounted_ticket_revenue.cents * organisation_revenue_share) + donation_revenue.cents).to_f / 100) - (credit_payable_to_organisation || 0)
  end

  def credit_payable_to_organisation
    credit_applied - credit_payable_to_revenue_sharer if organisation_revenue_share && credit_applied && credit_applied.positive?
  end

  def credit_payable_to_revenue_sharer
    ((discounted_ticket_revenue / (discounted_ticket_revenue + donation_revenue)) * credit_applied * (1 - organisation_revenue_share)).to_f if organisation_revenue_share && credit_applied && credit_applied.positive? && (discounted_ticket_revenue + donation_revenue).positive?
  end

  def make_transfer
    return unless event.revenue_sharer_organisationship && credit_payable_to_revenue_sharer && credit_payable_to_revenue_sharer.positive?

    Stripe.api_key = event.organisation.stripe_sk
    Stripe.api_version = '2020-08-27'
    transfer = Stripe::Transfer.create({
                                         amount: (credit_payable_to_revenue_sharer * 100).round,
                                         currency: currency,
                                         destination: event.revenue_sharer_organisationship.stripe_user_id,
                                         metadata: metadata
                                       })
    set(transfer_id: transfer.id)
  end

  def tickets_pdf
    order = self
    unit = 2.83466666667 # units / mm
    cm = 10 * unit
    width = 21 * cm
    margin = 1 * cm
    qr_size = width / 1.5
    Prawn::Document.new(page_size: 'A4', margin: margin) do |pdf|
      order.tickets.each_with_index do |ticket, i|
        pdf.start_new_page unless i.zero?
        pdf.font "#{Padrino.root}/app/assets/fonts/PlusJakartaSans/ttf/PlusJakartaSans-Regular.ttf"
        pdf.image (event.organisation.send_ticket_emails_from_organisation && event.organisation.image ? URI.parse(Addressable::URI.escape(event.organisation.image.url)).open : "#{Padrino.root}/app/assets/images/black-on-transparent-trim.png"), width: width / 4, position: :center
        pdf.move_down 0.5 * cm
        pdf.text order.event.name, align: :center, size: 32
        pdf.move_down 0.5 * cm
        pdf.text order.event.when_details(order.account.time_zone), align: :center, size: 14
        pdf.move_down 0.5 * cm
        pdf.indent((width / 2) - (qr_size / 2) - margin) do
          pdf.print_qr_code ticket.id.to_s, extent: qr_size
        end
        pdf.move_down 0.5 * cm
        pdf.text ticket.account.name, align: :center, size: 14
        if ticket.ticket_type
          pdf.move_down 0.5 * cm
          pdf.text ticket.ticket_type.name, align: :center, size: 14
        end
        pdf.move_down 0.5 * cm
        pdf.text ticket.id.to_s, align: :center, size: 10
      end
    end
  end

  def send_tickets
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_TICKETS_HOST'])

    order = self
    event = order.event

    account = order.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/tickets.erb'))).result(binding)
    batch_message.subject(event.ticket_email_title || "#{tickets.count == 1 ? 'Ticket' : 'Tickets'} to #{event.name}")

    if event.organisation.send_ticket_emails_from_organisation && event.organisation.reply_to && event.organisation.image
      header_image_url = event.organisation.image.url
      batch_message.from event.organisation.reply_to
      batch_message.reply_to event.email
    else
      header_image_url = "#{ENV['BASE_URI']}/images/black-on-transparent-sq.png"
      batch_message.from ENV['TICKETS_EMAIL_FULL']
      batch_message.reply_to(event.email || event.organisation.reply_to)
    end

    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    unless event.no_tickets_pdf
      tickets_pdf_filename = "dandelion-#{event.name.parameterize}-#{order.id}.pdf"
      tickets_pdf_file = File.new(tickets_pdf_filename, 'w+')
      tickets_pdf_file.write order.tickets_pdf.render
      tickets_pdf_file.rewind
      batch_message.add_attachment tickets_pdf_file, tickets_pdf_filename
    end

    cal = event.ical(order: order)
    ics_filename = "dandelion-#{event.name.parameterize}-#{order.id}.ics"
    ics_file = File.new(ics_filename, 'w+')
    ics_file.write cal.to_ical
    ics_file.rewind
    batch_message.add_attachment ics_file, ics_filename

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    if ENV['MAILGUN_API_KEY']
      message_ids = batch_message.finalize
      update_attribute(:message_ids, message_ids)
    end

    unless event.no_tickets_pdf
      tickets_pdf_file.close
      File.delete(tickets_pdf_filename)
    end
    ics_file.close
    File.delete(ics_filename)
  end
  handle_asynchronously :send_tickets

  def create_order_notification
    send_notification if event.send_order_notifications
    Notification.and(type: 'created_order').and(:notifiable_id.in => event.orders.and(account: account).pluck(:id)).destroy_all
    notifications.create! circle: circle, type: 'created_order' if account.public? && event.public?
  end

  def send_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    order = self
    event = order.event
    account = order.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/order.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "New order for #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    event.event_facilitators.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_notification

  def sign_up_to_gocardless
    return unless [gc_plan_id, gc_given_name, gc_family_name, gc_address_line1, gc_city, gc_postal_code, gc_branch_code, gc_account_number].all?(&:present?)

    f = Ferrum::Browser.new
    f.go_to("https://pay.gocardless.com/#{gc_plan_id}")
    sleep 5
    f.at_css('#given_name').focus.type(gc_given_name)
    f.at_css('#family_name').focus.type(gc_family_name)
    f.at_css('#email').focus.type(account.email)
    # f.screenshot(path: 'screenshot1.png')
    f.css('form button[type=button]').last.scroll_into_view.click
    sleep 5
    f.at_css('#address_line1').focus.type(gc_address_line1)
    f.at_css('#city').focus.type(gc_city)
    f.at_css('#postal_code').focus.type(gc_postal_code)
    # f.screenshot(path: 'screenshot2.png')
    f.at_css('form button[type=submit]').scroll_into_view.click
    sleep 5
    f.at_css('#branch_code').focus.type(gc_branch_code)
    f.at_css('#account_number').focus.type(gc_account_number)
    # f.screenshot(path: 'screenshot3.png')
    f.at_css('form button[type=submit]').scroll_into_view.click
    sleep 5
    # f.screenshot(path: 'screenshot4.png')
    f.at_css('button[type=submit]').scroll_into_view.click
    # sleep 5
    # f.screenshot(path: 'screenshot5.png')
    %i[gc_plan_id gc_given_name gc_family_name gc_address_line1 gc_city gc_postal_code gc_branch_code gc_account_number].each { |f| set(f => nil) }
    set(gc_success: true)
  end
  handle_asynchronously :sign_up_to_gocardless
end
