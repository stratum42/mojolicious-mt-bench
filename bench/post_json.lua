-- wrk Lua script for POST /json benchmark (50-record JSON payload)
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"

local parts = {}
for i = 1, 50 do
  local role = (i % 5 == 0) and "admin" or "member"
  local active = (i % 3 ~= 0) and "true" or "false"
  local score = string.format("%.2f", 10.5 + i * 1.25)
  parts[i] = string.format(
    '{"id":%d,"name":"User %d <dev> & \\"ops\\"","email":"user%d@example.com","role":"%s","active":%s,"score":%s}',
    i, i, i, role, active, score
  )
end

wrk.body = '{"status":"req","items":[' .. table.concat(parts, ",") .. ']}'
