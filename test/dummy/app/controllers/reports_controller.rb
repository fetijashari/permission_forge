# No Report model exists: this controller maps to no Resource. It does not
# include the action guard either, so nothing is ever checked here.
class ReportsController < ApplicationController
  def index = head(:ok)
end
