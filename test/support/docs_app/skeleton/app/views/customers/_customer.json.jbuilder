json.extract! customer, :id, :name, :email, :phone, :status, :notes, :owner_id, :created_at, :updated_at
json.url customer_url(customer, format: :json)
