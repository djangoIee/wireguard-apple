// SPDX-License-Identifier: MIT
// Copyright © 2018 WireGuard LLC. All Rights Reserved.

import Foundation
import Network
import NetworkExtension
import os.log

enum PacketTunnelProviderError: Error {
    case savedProtocolConfigurationIsInvalid
    case dnsResolutionFailure
    case couldNotStartWireGuard
    case coultNotSetNetworkSettings
}

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var wgHandle: Int32?

    private var networkMonitor: NWPathMonitor?

    deinit {
        networkMonitor?.cancel()
    }

    //swiftlint:disable:next function_body_length
    override func startTunnel(options: [String: NSObject]?, completionHandler startTunnelCompletionHandler: @escaping (Error?) -> Void) {

        let activationAttemptId = options?["activationAttemptId"] as? String
        let errorNotifier = ErrorNotifier(activationAttemptId: activationAttemptId, tunnelProvider: self)

        guard let tunnelProviderProtocol = protocolConfiguration as? NETunnelProviderProtocol,
            let tunnelConfiguration = tunnelProviderProtocol.tunnelConfiguration() else {
                errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
                startTunnelCompletionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
                return
        }

        configureLogger()

        let tunnelName = tunnelConfiguration.interface.name
        wg_log(.info, message: "Starting tunnel '\(tunnelName)'")

        if activationAttemptId != nil {
            wg_log(.info, staticMessage: "Tunnel activated from the app")
        } else {
            wg_log(.info, staticMessage: "Tunnel not activated from the app")
        }

        let isActivateOnDemandEnabled = tunnelProviderProtocol.isActivateOnDemandEnabled
        if isActivateOnDemandEnabled {
            wg_log(.info, staticMessage: "Tunnel has Activate On Demand enabled")
        } else {
            wg_log(.info, staticMessage: "Tunnel has Activate On Demand disabled")
        }

        errorNotifier.isActivateOnDemandEnabled = isActivateOnDemandEnabled
        errorNotifier.tunnelName = tunnelName

        let endpoints = tunnelConfiguration.peers.map { $0.endpoint }
        guard let resolvedEndpoints = resolveDomainNames(endpoints: endpoints) else {
            wg_log(.error, staticMessage: "Starting tunnel failed: DNS resolution failure")
            let dnsError = PacketTunnelProviderError.dnsResolutionFailure
            errorNotifier.notify(dnsError)
            startTunnelCompletionHandler(dnsError)
            return
        }
        assert(endpoints.count == resolvedEndpoints.count)

        let packetTunnelSettingsGenerator = PacketTunnelSettingsGenerator(tunnelConfiguration: tunnelConfiguration, resolvedEndpoints: resolvedEndpoints)

        let fileDescriptor = packetFlow.value(forKeyPath: "socket.fileDescriptor") as! Int32 //swiftlint:disable:this force_cast
        if fileDescriptor < 0 {
            wg_log(.error, staticMessage: "Starting tunnel failed: Could not determine file descriptor")
            errorNotifier.notify(PacketTunnelProviderError.couldNotStartWireGuard)
            startTunnelCompletionHandler(PacketTunnelProviderError.couldNotStartWireGuard)
            return
        }

        let wireguardSettings = packetTunnelSettingsGenerator.uapiConfiguration()

        var handle: Int32 = -1

        func interfaceDescription(_ interface: NWInterface?) -> String {
            if let interface = interface {
                return "\(interface.name) (\(interface.type))"
            } else {
                return "None"
            }
        }

        networkMonitor = NWPathMonitor()
        var previousPrimaryNetworkPathInterface = networkMonitor?.currentPath.availableInterfaces.first
        wg_log(.debug, message: "Network path primary interface: \(interfaceDescription(previousPrimaryNetworkPathInterface))")
        networkMonitor?.pathUpdateHandler = { path in
            guard handle >= 0 else { return }
            if path.status == .satisfied {
                wg_log(.debug, message: "Network change detected, re-establishing sockets and IPs: \(path.availableInterfaces)")
                let primaryNetworkPathInterface = path.availableInterfaces.first
                wg_log(.debug, message: "Network path primary interface: \(interfaceDescription(primaryNetworkPathInterface))")
                let shouldIncludeListenPort = previousPrimaryNetworkPathInterface != primaryNetworkPathInterface
                let endpointString = packetTunnelSettingsGenerator.endpointUapiConfiguration(shouldIncludeListenPort: shouldIncludeListenPort, currentListenPort: wgGetListenPort(handle))
                let err = withStringsAsGoStrings(endpointString, call: { return wgSetConfig(handle, $0.0) })
                if err == -EADDRINUSE {
                    // We expect this to happen only if shouldIncludeListenPort is true
                    let endpointString = packetTunnelSettingsGenerator.endpointUapiConfiguration(shouldIncludeListenPort: shouldIncludeListenPort, currentListenPort: 0)
                    _ = withStringsAsGoStrings(endpointString, call: { return wgSetConfig(handle, $0.0) })
                }
                previousPrimaryNetworkPathInterface = primaryNetworkPathInterface
            }
        }
        networkMonitor?.start(queue: DispatchQueue(label: "NetworkMonitor"))

        handle = connect(interfaceName: tunnelConfiguration.interface.name, settings: wireguardSettings, fileDescriptor: fileDescriptor)

        if handle < 0 {
            wg_log(.error, staticMessage: "Starting tunnel failed: Could not start WireGuard")
            errorNotifier.notify(PacketTunnelProviderError.couldNotStartWireGuard)
            startTunnelCompletionHandler(PacketTunnelProviderError.couldNotStartWireGuard)
            return
        }

        wgHandle = handle

        let networkSettings: NEPacketTunnelNetworkSettings = packetTunnelSettingsGenerator.generateNetworkSettings()
        setTunnelNetworkSettings(networkSettings) { error in
            if let error = error {
                wg_log(.error, staticMessage: "Starting tunnel failed: Error setting network settings.")
                wg_log(.error, message: "Error from setTunnelNetworkSettings: \(error.localizedDescription)")
                errorNotifier.notify(PacketTunnelProviderError.coultNotSetNetworkSettings)
                startTunnelCompletionHandler(PacketTunnelProviderError.coultNotSetNetworkSettings)
            } else {
                startTunnelCompletionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        networkMonitor?.cancel()
        networkMonitor = nil

        ErrorNotifier.removeLastErrorFile()

        wg_log(.info, staticMessage: "Stopping tunnel")
        if let handle = wgHandle {
            wgTurnOff(handle)
        }
        completionHandler()
    }

    private func configureLogger() {
        Logger.configureGlobal(withFilePath: FileManager.networkExtensionLogFileURL?.path)
        wgSetLogger { level, msgC in
            guard let msgC = msgC else { return }
            let logType: OSLogType
            switch level {
            case 0:
                logType = .debug
            case 1:
                logType = .info
            case 2:
                logType = .error
            default:
                logType = .default
            }
            wg_log(logType, message: String(cString: msgC))
        }
    }

    private func resolveDomainNames(endpoints: [Endpoint?]) -> [Endpoint?]? {
        do {
            return try DNSResolver.resolveSync(endpoints: endpoints)
        } catch DNSResolverError.dnsResolutionFailed(let hostnames) {
            wg_log(.error, message: "DNS resolution failed for the following hostnames: \(hostnames.joined(separator: ", "))")
        } catch {
            // There can be no other errors from DNSResolver.resolveSync()
            fatalError()
        }
        return nil
    }

    private func connect(interfaceName: String, settings: String, fileDescriptor: Int32) -> Int32 {
        return withStringsAsGoStrings(interfaceName, settings) { return wgTurnOn($0.0, $0.1, fileDescriptor) }
    }
}

// swiftlint:disable:next large_tuple identifier_name
func withStringsAsGoStrings<R>(_ s1: String, _ s2: String? = nil, _ s3: String? = nil, _ s4: String? = nil, call: ((gostring_t, gostring_t, gostring_t, gostring_t)) -> R) -> R {
    // swiftlint:disable:next large_tuple identifier_name
    func helper(_ p1: UnsafePointer<Int8>?, _ p2: UnsafePointer<Int8>?, _ p3: UnsafePointer<Int8>?, _ p4: UnsafePointer<Int8>?, _ call: ((gostring_t, gostring_t, gostring_t, gostring_t)) -> R) -> R {
        return call((gostring_t(p: p1, n: s1.utf8.count), gostring_t(p: p2, n: s2?.utf8.count ?? 0), gostring_t(p: p3, n: s3?.utf8.count ?? 0), gostring_t(p: p4, n: s4?.utf8.count ?? 0)))
    }
    return helper(s1, s2, s3, s4, call)
}
