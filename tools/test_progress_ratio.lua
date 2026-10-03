-- beta.26: explicit percent vs ratio boundary, especially value==1.
local function normalize_ratio(value)
    value=tonumber(value)
    if not value then return nil end
    if value>1 then value=value/100 end
    if value<0 then return 0 elseif value>1 then return 1 end
    return value
end
local function percent_to_ratio(value)
    value=tonumber(value)
    if not value then return nil end
    return math.max(0,math.min(1,value/100))
end
assert(percent_to_ratio(1)==0.01,'WeRead percent 1 must be 1%')
assert(percent_to_ratio(50)==0.5,'50 percent')
assert(percent_to_ratio(100)==1,'100 percent')
assert(normalize_ratio(1)==1,'ratio 1 remains 100%')
assert(normalize_ratio(0.01)==0.01,'ratio 0.01 remains 1%')
print('progress ratio: PASS')
