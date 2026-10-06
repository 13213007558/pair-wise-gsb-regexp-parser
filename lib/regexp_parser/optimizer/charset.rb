# frozen_string_literal: true

require 'set'

class Regexp::Parser
  module Optimizer
    # A finite set of characters (codepoints). +nil+ represents the unknown /
    # unbounded alphabet (\x{any}), which is handled as the universal set for
    # intersection tests. This keeps every decision conservative: anything
    # that cannot be proven with a finite alphabet blocks the optimization.
    module Charset
      ANY = :any

      def self.set(codepoints = nil)
        return ANY if codepoints.nil?
        codepoints.is_a?(::Set) ? codepoints : codepoints.to_set
      end

      def self.unknown?(*sets)
        sets.any? { |chars| chars.equal?(ANY) }
      end

      def self.union(left, right)
        return ANY if unknown?(left, right)
        left | right
      end

      def self.intersect?(left, right)
        return true if unknown?(left, right)
        !(left & right).empty?
      end

      # Codepoints that compare equal to +char+ under Ruby's case folding.
      # Computed from the actual Ruby engine once per character, so /i rules
      # (including non-ASCII folding) are never guessed.
      def self.case_partners(codepoint)
        @partners ||= {}
        # String#casecmp? is only available on Ruby >= 2.4. Without it we
        # cannot safely enumerate folding partners, so treat as unbounded.
        return ANY unless ''.respond_to?(:casecmp?)
        @partners[codepoint] ||= begin
          reference = codepoint.chr(Encoding::UTF_8)
          partners = Set[codepoint]
          0x110000.times do |other|
            next if other == codepoint
            candidate = begin
                          other.chr(Encoding::UTF_8)
                        rescue RangeError
                          nil
                        end
            partners << other if candidate && reference.casecmp?(candidate)
          end
          partners
        end
      end
    end
  end
end
