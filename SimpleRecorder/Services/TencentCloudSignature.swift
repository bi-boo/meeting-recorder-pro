import Foundation
import CommonCrypto

struct TencentCloudSignature {
    static func generateAuthorization(
        secretId: String,
        secretKey: String,
        service: String,
        action: String,
        version: String,
        region: String,
        timestamp: Int,
        payload: String,
        host: String
    ) -> String {
        let algorithm = "TC3-HMAC-SHA256"
        let date = formatDate(timestamp)
        
        // 1. 构建规范请求串
        let httpRequestMethod = "POST"
        let canonicalURI = "/"
        let canonicalQueryString = ""
        let canonicalHeaders = "content-type:application/json; charset=utf-8\nhost:\(host)\nx-tc-action:\(action.lowercased())\n"
        let signedHeaders = "content-type;host;x-tc-action"
        let hashedPayload = sha256hex(payload)
        
        let canonicalRequest = "\(httpRequestMethod)\n\(canonicalURI)\n\(canonicalQueryString)\n\(canonicalHeaders)\n\(signedHeaders)\n\(hashedPayload)"
        
        // 2. 构建待签名字符串
        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = "\(algorithm)\n\(timestamp)\n\(credentialScope)\n\(sha256hex(canonicalRequest))"
        
        // 3. 计算签名
        let kDate = hmacSha256(key: "TC3\(secretKey)".data(using: .utf8)!, data: date.data(using: .utf8)!)
        let kService = hmacSha256(key: kDate, data: service.data(using: .utf8)!)
        let kSigning = hmacSha256(key: kService, data: "tc3_request".data(using: .utf8)!)
        let signature = hmacSha256(key: kSigning, data: stringToSign.data(using: .utf8)!).map { String(format: "%02x", $0) }.joined()
        
        // 4. 构建 Authorization
        return "\(algorithm) Credential=\(secretId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }
    
    private static func formatDate(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
    
    private static func sha256hex(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    private static func hmacSha256(key: Data, data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, key.count, dataBytes.baseAddress, data.count, &result)
            }
        }
        return Data(result)
    }
}
