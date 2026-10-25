--!strict
-- Wire signing for the lobby service (docs/lobby-service.md "Auth"); pure, so Lune tests it against
-- the Node service. Same format as the Tribes matchmaker:
--   request:  X-TM-Sig = hex HMAC-SHA256(secret, "v1\n" .. ts .. "\n" .. nonce .. "\n" .. METHOD .. "\n" .. path .. "\n" .. body)
--   response: X-TM-Sig = hex HMAC-SHA256(secret, "v1r\n" .. requestNonce .. "\n" .. status .. "\n" .. body)
local Sha256 = require("./Sha256")

local Signing = {}

function Signing.request(secret: string, ts: number, nonce: string, method: string, path: string, body: string): string
	return Sha256.HmacHex(secret, `v1\n{string.format("%d", ts)}\n{nonce}\n{string.upper(method)}\n{path}\n{body}`)
end

function Signing.response(secret: string, nonce: string, status: number, body: string): string
	return Sha256.HmacHex(secret, `v1r\n{nonce}\n{string.format("%d", status)}\n{body}`)
end

function Signing.verify_response(secret: string, nonce: string, status: number, body: string, sig: string?): boolean
	if type(sig) ~= "string" or #sig ~= 64 then
		return false
	end
	return Sha256.Equal(string.lower(sig), Signing.response(secret, nonce, status, body))
end

--- Response headers keep the server's casing; look them up case-insensitively.
function Signing.header(headers: { [string]: string }?, name: string): string?
	if not headers then
		return nil
	end
	local want = string.lower(name)
	for k, v in headers do
		if string.lower(k) == want then
			return v
		end
	end
	return nil
end

return Signing
