# frozen_string_literal: true

# A negative fixture for IntegerParamGuardTest. Never required.
module ReadsIntegerParam
  def page = params[:page].to_i
  def per_page(paging) = paging[:per_page].to_s.to_i
end
