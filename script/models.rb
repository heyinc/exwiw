class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

class Shop < ApplicationRecord
  has_many :users
  has_many :products
  has_many :orders
  has_many :reviews, as: :reviewable
end

class User < ApplicationRecord
  belongs_to :shop
end

class Product < ApplicationRecord
  belongs_to :shop
  has_many :order_items
  has_many :orders, through: :order_items
  has_many :reviews, as: :reviewable
end

class Order < ApplicationRecord
  belongs_to :shop
  belongs_to :user
  has_many :order_items
  has_many :products, through: :order_items
  has_one :payment_transaction
  has_one :refund_transaction
end

class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product
end

class Transaction < ApplicationRecord
end

class PaymentTransaction < Transaction
  belongs_to :order
end

class RefundTransaction < Transaction
  belongs_to :order
end

class Review < ApplicationRecord
  belongs_to :reviewable, polymorphic: true
  belongs_to :user
end

class SystemAnnouncement < ApplicationRecord
end
