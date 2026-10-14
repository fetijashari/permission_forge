# frozen_string_literal: true

# Tests replace a method for a while by hand (minitest/mock is not available
# under Minitest 6). Defining a method over one that is there makes Ruby warn
# "method redefined" under `-w`, once when the stand-in goes in and once when
# the original comes back: these helpers remove the method first, so the
# suite's warnings are the ones worth reading.
module MethodStubs
  private

  # `object.define_singleton_method(name, method)` (or with the block),
  # without the warning.
  def replace_singleton_method(object, name, method = nil, &)
    replace_method(object.singleton_class, name, method, &)
  end

  # `owner.define_method(name, method)` (or with the block), without the
  # warning. The method is public, as with define_method.
  def replace_method(owner, name, method = nil, &)
    owner.send(:remove_method, name) if owner.method_defined?(name, false) || owner.private_method_defined?(name, false)
    method ? owner.send(:define_method, name, method) : owner.send(:define_method, name, &)
  end
end
