require_relative 'pinhole.rb'
$Verbose = 0
blacksmith = Blacksmith.new
S = blacksmith

puts "S <- #{S}"
var = 'REACTOR_TEST_ORG_ID'
if ENV[var] =~ /^[0-9A-F]{24}@AdobeOrg$/i
  O = Org.find(S, id: ENV[var])
  puts "O <- #{O.id} (from $#{var})"
end
var  = 'REACTOR_TEST_COMPANY_ID'
if ENV[var] =~ /^CO[0-9a-fA-F]{32}$/
  C = Company.find(S, id: ENV[var])
  puts "C <- #{C.id} (from $#{var}) #{C.name}"
end
var  = 'REACTOR_TEST_PROPERTY_ID'
if ENV[var] =~ /^PR[0-9a-fA-F]{32}$/
  P = Property.find(S, id: ENV[var])
  puts "P <- #{P.id} (from $#{var}) #{P.name}"
end
var  = 'REACTOR_TEST_LIBRARY_ID'
if ENV[var] =~ /^LB[0-9a-fA-F]{32}$/
  L = Library.find(S, id: ENV[var])
  puts "L <- #{L.id} (from $#{var}) #{L.name}"
end
var  = 'REACTOR_TEST_BUILD_ID'
if ENV[var] =~ /^BL[0-9a-fA-F]{32}$/
  B = Build.find(S, id: ENV[var])
  puts "B <- #{B.id} (from $#{var}) #{B.name}"
end

$Verbose = ENV['PINHOLE_VERBOSITY'] =~ /^\d+$/ ? $&.to_i :  2
