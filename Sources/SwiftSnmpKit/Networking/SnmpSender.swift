//
//  File.swift
//  
//
//  Created by Darrell Root on 7/12/22.
//

import Foundation
import NIOCore
import NIOPosix

/// SnmpSender is a singleton class which handles sending and receiving SNMP messages
/// It maintains several internal state tables to record SNMP
/// EngineIDs, EngineBoots, and BootDates gathered from SNMPv3 reports
public class SnmpSender/*: ChannelInboundHandler*/ {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    
    static let snmpPort = 161
    /// This is a singleton for sending and receiving Snmp traffic
    /// It is automatically started up by any application that incorporates SnmpKit
    public static let shared: SnmpSender? = try? SnmpSender()
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    
    /// Set this to true to print verbose debugging messages
    /// See SnmpError.debug()
    public static var debug = false
    /// Global timeout for SnmpRequests in seconds.
    /// Must be greater than 0.  SNMPv3 send requests sometimes
    /// require 3 attempts, so the client-facing timeout may be 3 times
    /// this value.
    public static var snmpTimeout: UInt64 = 5

    // maps messageID to decryption key
    internal var localizedKeys: [Int32:[UInt8]] = [:]
    
    /// This is a record of outstanding SNMP requests and the continuation
    /// that must be called when the reply is received.  The continuation
    /// could also be triggered by a timeout.  Triggering the same continuation twice will trigger a crash.
    private var snmpRequests: [Int32:CheckedContinuation<Result<SnmpVariableBinding, Error>, Never>] = [:]
    
    /// Key is SNMP Agent hostname or IP in String format
    /// Value is SnmpEngineBoots Int as reported by SNMP agent
    /// These are gathered from SNMPv3 reports
    internal var snmpEngineBoots: [String:Int] = [:]
    /// Key is SNMP Agent hostname or IP in String format
    ///  Value is Date of most recent boot
    ///  These are gathered from SNMPv3 reports
    internal var snmpEngineBootDate: [String:Date] = [:]
    /// Maps SNMPv3 requestID/MessageID to hostname
    internal var snmpRequestToHost: [Int32:String] = [:]
    /// Maps SNMP agent hostname to EngineId.  Gathered from SNMPv3 reports.
    internal var snmpHostToEngineId: [String:String] = [:]
    
    private init() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let bootstrap = DatagramBootstrap(group: group).channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                SnmpError.debug("adding handler")
                return channel.pipeline.addHandler(SnmpReceiver())
            }
        let channel = try bootstrap.bind(host: "0.0.0.0", port: 0).wait()
        /*bootstrap.channelInitializer { channel in
            channel.pipeline.addHandler(SnmpReceiver())
        }*/
        self.channel = channel
    }
    
    deinit {
        SnmpError.log("Deinitializing SnmpSender Singleton")
        do {
            try self.group.syncShutdownGracefully()
        } catch {}
    }
    
    /// After sending a message this internal function triggers a timeout
    /// - Parameters:
    ///   - message: SNMP message that was sent
    ///   - continuation: The continuation to trigger
    ///   Warning: triggering the same continuation twice will trigger a crash.
    internal func sent(message: SnmpMessage, continuation: CheckedContinuation<Result<SnmpVariableBinding, Error>, Never>) {
        let requestId = message.requestID()
        snmpRequests[requestId] = continuation
        Task.detached {
            try? await Task.sleep(nanoseconds: SnmpSender.snmpTimeout * 1_000_000_000)
            self.triggerTimeoutForRequestIfNeeded(id: requestId)
        }
    }
    
    func triggerTimeoutForRequestIfNeeded(id: Int32) {
        if let continuation = snmpRequests.removeValue(forKey: id) {
            continuation.resume(with: .success(.failure(SnmpError.noResponse)))
        }
    }
    
    internal func received(message: SnmpMessage) {
        switch message.version {
        case .v1, .v2c:
            guard let continuation = snmpRequests[message.requestID()] else {
                return
            }
            guard message.errorStat() == 0 && message.varBinds().count > 0 else {
                snmpRequests[message.requestID()] = nil
                continuation.resume(with: .success(.failure(SnmpError.snmpResponseError)))
                return
            }
            var output = ""
            for variableBinding in message.varBinds() {
                output.append(variableBinding.description)
            }
            snmpRequests[message.requestID()] = nil
            continuation.resume(with: .success(.success(message.varBinds().first!)))
        case .v3:
            guard let message = message as? SnmpV3Message else { return }
            guard let continuation = snmpRequests[message.messageId] else {
                return
            }
            snmpRequests[message.messageId] = nil
            let snmpPdu = message.snmpPdu
            guard snmpPdu.errorStatus == 0 && snmpPdu.variableBindings.count > 0 else {
                continuation.resume(with: .success(.failure(SnmpError.snmpResponseError)))
                return
            }
            guard snmpPdu.pduType != .snmpReport else {
                guard let variableBinding = snmpPdu.variableBindings.first else {
                    continuation.resume(with: .success(.failure(SnmpError.snmpResponseError)))
                    return
                }
                switch variableBinding.oid {
                case SnmpOid("1.3.6.1.6.3.15.1.1.1.0"):
                    continuation.resume(with: .success(.failure(SnmpError.snmpUnknownSecurityLevel)))
                case SnmpOid("1.3.6.1.6.3.15.1.1.2.0"):
                    let engineBoots = message.engineBoots
                    let engineTime = message.engineTime
                    let engineBootTime = Date(timeIntervalSinceNow: -Double(engineTime))
                    if let agentHostname = self.snmpRequestToHost[message.messageId] {
                        self.snmpEngineBoots[agentHostname] = engineBoots
                        self.snmpEngineBootDate[agentHostname] = engineBootTime
                    }
                    continuation.resume(with: .success(.failure(SnmpError.snmpNotInTimeWindow)))
                case SnmpOid("1.3.6.1.6.3.15.1.1.3.0"):
                    continuation.resume(with: .success(.failure(SnmpError.snmpUnknownUser)))
                case SnmpOid("1.3.6.1.6.3.15.1.1.4.0"):
                    if let host = snmpRequestToHost[message.messageId] {
                        if !message.engineId.isEmpty {
                            snmpHostToEngineId[host] = message.engineId.hexString
                        }
                    }
                    continuation.resume(with: .success(.failure(SnmpError.snmpUnknownEngineId)))
                case SnmpOid("1.3.6.1.6.3.15.1.1.5.0"):
                    continuation.resume(with: .success(.failure(SnmpError.snmpAuthenticationError)))
                case SnmpOid("1.3.6.1.6.3.15.1.1.6.0"):
                    continuation.resume(with: .success(.failure(SnmpError.snmpDecryptionError)))
                default:
                    continuation.resume(with: .success(.failure(SnmpError.snmpResponseError)))
                }
                return
            }
            var output = ""
            for variableBinding in snmpPdu.variableBindings {
                output.append(variableBinding.description)
            }
            snmpRequests[message.messageId] = nil
            snmpRequestToHost[message.messageId] = nil
            SnmpError.debug("about to continue \(continuation)")
            continuation.resume(with: .success(.success(snmpPdu.variableBindings.first!)))
        }
    }
    
    /// Sends a SNMPv1 or SNMPv2c Get request asynchronously and adds the requestID to the list of expected responses
    /// - Parameters:
    ///   - host: IPv4, IPv6, or hostname in String format
    ///   - command: A SnmpPduType.  At this time we only support .getRequest and .getNextRequest
    ///   - community: SNMPv2c community in String format
    ///   - oid: SnmpOid to be requested
    /// - Returns: Result(SnmpVariableBinding or SnmpError)
    public func sendV1OrV2(
        host: String,
        command: SnmpPduType,
        community: String,
        oid: String,
        isV1: Bool
    ) async -> Result<SnmpVariableBinding,Error> {
        guard let oid = SnmpOid(oid) else {
            return .failure(SnmpError.invalidOid)
        }
        // At this time we only support SNMP get and getNext
        guard command == .getRequest || command == .getNextRequest else {
            return .failure(SnmpError.unsupportedType)
        }
        let snmpMessage: SnmpMessage = isV1 ?
            SnmpV1Message(community: community, command: command, oid: oid) :
            SnmpV2Message(community: community, command: command, oid: oid)
        guard let remoteAddress = try? SocketAddress(ipAddress: host, port: SnmpSender.snmpPort) else {
            return .failure(SnmpError.invalidAddress)
        }
        let data = snmpMessage.asnData
        let buffer = channel.allocator.buffer(bytes: data)
        let envelope = AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)
        do {
            let _ = try await channel.writeAndFlush(envelope)
        } catch (let error) {
            return .failure(error)
        }
        return await withCheckedContinuation { continuation in
            //snmpRequests[snmpMessage.requestId] = continuation.resume(with:)
            SnmpError.debug("adding snmpRequests \(snmpMessage.requestID())")
            sent(message: snmpMessage, continuation: continuation)
            //snmpRequests[snmpMessage.requestId] = continuation
        }
    }
    
    /// Sends a SNMPv3 request asynchronously up to three times
    /// This allows SnmpSender to discover the engineID and timeout
    /// - Parameters:
    ///   - host: SNMP hostname, IPv4, or IPv6 address in string format
    ///   - tempUserName: SNMPv3 agent username
    ///   - pduType: SNMP PDU request type
    ///   - oid: SNMP OID in string format
    ///   - tempAuthenticationType: SNMPv3 authentication type
    ///   - tempPassword: SNMPv3 password if needed, or nil
    /// - Returns: Result(SnmpVariableBinding or SnmpError)
    public func sendV3(host: String, userName: String, pduType: SnmpPduType, oid: String, authenticationType: SnmpV3Authentication = .noAuth, authPassword: String? = nil, privPassword: String? = nil) async -> Result<SnmpVariableBinding,Error> {
        guard pduType == .getRequest || pduType == .getNextRequest else {
            return .failure(SnmpError.unsupportedType)
        }
        guard let oid = SnmpOid(oid) else {
            return .failure(SnmpError.invalidOid)
        }
        // attempt #1 (may get engineId)
        let result1 = await self.sendV3(host: host, userName: userName, pduType: pduType, oid: oid, authenticationType: authenticationType, authPassword: authPassword, privPassword: privPassword)
        guard case let .failure(_) = result1 else {
            return result1
        }
        // attempt #2 (may update time interval)
        let result2 = await self.sendV3(host: host, userName: userName, pduType: pduType, oid: oid, authenticationType: authenticationType, authPassword: authPassword, privPassword: privPassword)
        guard case let .failure(_) = result2 else {
            return result2
        }
        // attempt #3 (last chance!)
        let result3 = await self.sendV3(host: host, userName: userName, pduType: pduType, oid: oid, authenticationType: authenticationType, authPassword: authPassword, privPassword: privPassword)
        return result3
    }
    
    /// Sends a SNMPv3 Get request asynchronously ONCE and adds the requestID to the list of expected responses
    /// - Parameters:
    ///   - host: IPv4, IPv6, or hostname in String format
    ///   - command: A SnmpPduType.  At this time we only support .getRequest and .getNextRequest
    ///   - community: SNMPv2c community in String format
    ///   - oid: SnmpOid to be requested
    ///   - privacyPassword: Setting this turns on AES encryption
    /// - Returns: Result(SnmpVariableBinding or SnmpError)
    internal func sendV3(host: String, userName tempUserName: String, pduType: SnmpPduType, oid: SnmpOid, authenticationType tempAuthenticationType: SnmpV3Authentication = .noAuth, authPassword tempAuthPassword: String? = nil, privPassword tempPrivPassword: String? = nil) async -> Result<SnmpVariableBinding,Error> {
        // At this time we only support SNMP get and getNext
        guard pduType == .getRequest || pduType == .getNextRequest else {
            return .failure(SnmpError.unsupportedType)
        }
        let variableBinding = SnmpVariableBinding(oid: oid)
        let authenticationType: SnmpV3Authentication
        // send blank engineId if we don't know engineId
        var engineId: String
        var userName: String
        // If we don't know the engine-id or engine-time
        // we need to send unauthenticated snmp messages
        // with these passwords set to nil
        // so we don't directly use the function parameters
        var authPassword: String?
        var privPassword: String?
        if let possibleEngineId = snmpHostToEngineId[host] {
            engineId = possibleEngineId
            authenticationType = tempAuthenticationType
            userName = tempUserName
            authPassword = tempAuthPassword
            privPassword = tempPrivPassword
        } else {
            // trying to trigger a report rather than actually getting our data
            engineId = ""
            authenticationType = .noAuth
            userName = ""
            authPassword = nil
            privPassword = nil
        }
        guard let remoteAddress = try? SocketAddress(ipAddress: host, port: SnmpSender.snmpPort) else {
            return .failure(SnmpError.invalidAddress)
        }
        let engineBoots = snmpEngineBoots[host] ?? 0
        let bootDate = snmpEngineBootDate[host] ?? Date()
        let dateInterval = DateInterval(start: bootDate, end: Date())
        let engineTime = Int(dateInterval.duration)
        
        guard var snmpMessage = SnmpV3Message(engineId: engineId, userName: userName, type: pduType, variableBindings: [variableBinding], authenticationType: authenticationType, authPassword: authPassword, privPassword: privPassword, engineBoots: engineBoots, engineTime: engineTime) else {
            return .failure(SnmpError.unexpectedSnmpPdu)
        }

        let data = await snmpMessage.asnData
        let buffer = channel.allocator.buffer(bytes: data)
        let envelope = AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)
        do {
            let _ = try await channel.writeAndFlush(envelope)
            self.snmpRequestToHost[snmpMessage.messageId] = host
        } catch (let error) {
            return .failure(error)
        }
        return await withCheckedContinuation { continuation in
            SnmpError.debug("adding snmpRequests \(snmpMessage.messageId)")
            sent(message: snmpMessage, continuation: continuation)
        }
    }
}
