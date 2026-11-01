import Foundation
import Testing
@testable import PeelGoodRemote

// The worked examples in AWS's "Authenticating Requests: Using the Authorization Header". A fake
// server checking signatures with this same code would prove nothing.
private let signer = SigV4(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
private let date = Date(timeIntervalSince1970: 1369353600)  // 20130524T000000Z

@Test func signsAWSsGetObjectExample() {
    let h = signer.headers(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/test.txt", query: [:], extra: ["Range": "bytes=0-9"], date: date)
    #expect(h["authorization"] == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
}

@Test func signsAWSsListObjectsExample() {
    let h = signer.headers(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/", query: ["max-keys": "2", "prefix": "J"], date: date)
    #expect(h["authorization"]?.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
}

@Test func encodesLikeS3Expects() {
    #expect(SigV4.encodePath("/a b/é+c~.txt") == "/a%20b/%C3%A9%2Bc~.txt")
    #expect(SigV4.encodeQuery(["z": "1", "a b": "c/d"]) == "a%20b=c%2Fd&z=1")
}

@Test func onlySecureAddresses() throws {
    #expect(throws: RemoteError.self) { try SecureURL.check("http://s3.example.com") }
    #expect(throws: RemoteError.self) { try SecureURL.check("https://user:pw@s3.example.com") }
    _ = try SecureURL.check("https://s3.example.com")
    _ = try SecureURL.check("http://127.0.0.1:9000")
}
