import Foundation

@main
struct PrivateAddressTests {
    static func main() {
        let allowed = ["10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254",
                       "192.168.0.1", "192.168.255.254", "100.64.0.1", "100.127.255.254"]
        let rejected = ["8.8.8.8", "1.1.1.1", "127.0.0.1", "0.0.0.0", "169.254.1.1",
                        "100.63.255.255", "100.128.0.0", "172.15.255.255", "172.32.0.0",
                        "192.167.1.1", "192.169.1.1", "224.0.0.1", "255.255.255.255",
                        "localhost", "mac.local", "https://10.0.0.1", "10.0.0.1:8766",
                        "10.0.0.1@other.example", "10.0.0.1/path", "10.0.0.1?x=1",
                        "10.0.0.1#fragment", "010.0.0.1", "10.0.0.01", "0x0a.0.0.1",
                        "167772161", "10.1", "10..0.1", "10.0.0.256", "10.0.0.-1",
                        "10.0.0.1.", " 10.0.0.1", "10.0.0.1\n", "１０.0.0.1", "::1", ""]
        var checks = 0
        for host in allowed {
            precondition(PairingProfile.isPrivateIPv4(host), "Expected private IPv4: \(host)")
            let profile = PairingProfile(host: host, port: 8766, certificateFingerprint: "test")
            precondition(profile.baseURL?.absoluteString == "https://\(host):8766")
            checks += 2
        }
        for host in rejected {
            precondition(!PairingProfile.isPrivateIPv4(host), "Unexpected accepted address: \(host)")
            precondition(PairingProfile(host: host, port: 8766, certificateFingerprint: "test").baseURL == nil)
            checks += 2
        }
        for port in [-1, 0, 65536] {
            precondition(PairingProfile(host: allowed[0], port: port, certificateFingerprint: "test").baseURL == nil)
            checks += 1
        }
        print("Passed \(checks) private-address and HTTPS URL assertions.")
    }
}
