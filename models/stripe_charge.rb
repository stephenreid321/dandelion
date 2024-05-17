class StripeCharge
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :organisation, index: true
  belongs_to :event, optional: true, index: true
  belongs_to :order, optional: true, index: true
  belongs_to :account, optional: true, index: true

  has_many :stripe_transactions

  field :amount, type: Integer
  field :application_fee, type: String
  field :application_fee_amount, type: Integer
  field :balance_transaction, type: String
  field :created, type: Time
  field :currency, type: String
  field :customer, type: String
  field :description, type: String
  field :destination, type: String
  field :payment_intent, type: String
  field :de_donation_revenue, type: Float
  field :de_ticket_revenue, type: Float
  field :de_discounted_ticket_revenue, type: Float
  field :de_percentage_discount, type: Float
  field :de_percentage_discount_monthly_donor, type: Float
  field :de_credit_applied, type: Float

  def summary
    Money.new(amount, currency).format(no_cents_if_whole: true)
  end

  def self.admin_fields
    {
      summary: { type: :text, edit: false },
      organisation_id: :lookup,
      event_id: :lookup,
      order_id: :lookup,
      account_id: :lookup,
      amount: :number,
      application_fee: :text,
      application_fee_amount: :number,
      balance_transaction: :text,
      created: :datetime,
      currency: :text,
      customer: :text,
      description: :text,
      destination: { type: :text, full: true },
      payment_intent: :text,
      de_donation_revenue: :number,
      de_ticket_revenue: :number,
      de_discounted_ticket_revenue: :number,
      de_percentage_discount: :number,
      de_percentage_discount_monthly_donor: :number,
      de_credit_applied: :number,
      stripe_transactions: :collection
    }
  end

  def self.transfer_charges(organisation, from: Date.today - 2, to: Date.today - 1)
    puts "transferring charges for #{organisation.slug} from #{from} to #{to}"

    Stripe.api_key = organisation.stripe_sk
    Stripe.api_version = '2020-08-27'
    charges = Stripe::Charge.list(created: { gte: Time.utc(from.year, from.month, from.day).to_i, lt: Time.utc(to.year, to.month, to.day).to_i })

    charges.auto_paging_each do |charge|
      c = {}
      %w[id amount application_fee application_fee_amount balance_transaction created currency customer description destination payment_intent].each do |f|
        c[f] = case f
               when 'created'
                 Time.at(charge[f]).utc.strftime('%Y-%m-%d %H:%M:%S +0000')
               else
                 charge[f]
               end
      end
      %w[de_event_id de_order_id de_account_id].each do |f|
        c[f.gsub('de_', '')] = charge['metadata'][f]
      end
      %w[de_donation_revenue de_ticket_revenue de_discounted_ticket_revenue de_percentage_discount de_percentage_discount_monthly_donor de_credit_applied].each do |f|
        c[f] = charge['metadata'][f]
      end
      puts c
      organisation.stripe_charges.create!(c)
    end
  end

  def balance
    stripe_transactions.sum(:gross_gbp)
  end

  def fees
    stripe_transactions.sum(:fee_gbp)
  end
end
