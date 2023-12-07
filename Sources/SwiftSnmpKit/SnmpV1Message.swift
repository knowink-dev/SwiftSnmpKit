//
//  SnmpV1Message.swift
//
//
//  Created by Adam Hitt on 12/7/23.
//

import Foundation



/// Structure for the SNMP Message
public struct SnmpV1Message: AsnData, CustomDebugStringConvertible {
    
    
    /// SNMP version.  .v1 in this case.
    public private(set) var version: SnmpVersion
    /// SNMPv1 community
    public private(set) var community: String
    /// SNMP command
    public private(set) var command: SnmpPduType
    /// SNMP request ID
    public private(set) var requestId: Int32
    /// SNMP error status, primarily for SNMP replies
    public private(set) var errorStatus: Int
    /// SNMP error index, primarily for SNMP replies
    public private(set) var errorIndex: Int
    /// Array of SNMP variable bindings, each with an OID and ASN.1 value.
    public private(set) var variableBindings: [SnmpVariableBinding]
    
    /// A description of the SNMPv2c message suitable for debugging.
    public var debugDescription: String {
        var result = "\(self.version) \(self.community) \(self.command) requestId:\(self.requestId) errorStatus:\(self.errorStatus) errorIndex:\(self.errorIndex)\n"
        for variableBinding in variableBindings {
            result += "  \(variableBinding)\n"
        }
        return result
    }
    
    /// Outputs the SNMPv1 message as data for transmission
    internal var asnData: Data {
        let versionData = version.asnData
        let communityValue = AsnValue(octetString: community)
        let communityData = communityValue.asnData
        let pdu = SnmpPdu(type: command, requestId: requestId, variableBindings: variableBindings)
        let pduData = pdu.asnData
        let contentsData = versionData + communityData + pduData
        let lengthData = AsnValue.encodeLength(contentsData.count)
        let prefixData = Data([0x30])
        return prefixData + lengthData + contentsData
    }
    
    /// This initializer is used to create SNMP Messages for transmission
    /// - Parameters:
    ///   - version: SNMP version.  Default is v1
    ///   - community: SNMP community
    ///   - command: SNMP command. Could be get or getNext.  Replies are not valid for this initializer.
    ///   - oid: The SNMP OID to be requested
    public init(version: SnmpVersion = .v1, community: String, command: SnmpPduType, oid: SnmpOid) {
        self.version = version
        self.community = community
        self.command = command
        //self.requestId = Int32.random(in: Int32.min...Int32.max)
        self.requestId = Int32.random(in: 1...Int32.max)

        self.errorStatus = 0
        self.errorIndex = 0
        let variableBinding = SnmpVariableBinding(oid: oid)
        self.variableBindings = [variableBinding]
    }
    /// Creates SNMP message data structure from the data encapsulated inside a UDP SNMP reply.
    ///
    /// Takes data from a SNMP reply and uses it to create a SNMP message data structure.  Returns nil if the data cannot form a complete SNMP reply data structure.
    /// This initializer is not designed for creating a SNMP message for transmission.
    /// - Parameter data: The network contents of a UDP reply, with the IP and UDP headers already stripped off.
    public init?(data: Data) {
        guard let outerSequence = try? AsnValue(data: data) else {
            SnmpError.debug("Outer ASN is not a sequence")
            return nil
        }
        guard case .sequence(let contents) = outerSequence else {
            SnmpError.debug("Unable to extract AsnValues")
            return nil
        }
        guard contents.count > 0 else {
            SnmpError.debug("No contents")
            return nil
        }
        guard case .integer(let snmpVersionInteger) = contents[0] else {
            SnmpError.debug("Expected AsnInteger, got \(contents[0])")
            return nil
        }
        guard let snmpVersion = SnmpVersion(rawValue: Int(snmpVersionInteger)) else {
            SnmpError.debug("Received invalid SNMP Version \(snmpVersionInteger)")
            return nil
        }
        self.version = snmpVersion
        if snmpVersion != .v2c {
            return nil
        }
        guard contents.count == 3 else {
            SnmpError.debug("Expected 3 contents, found \(contents.count)")
            return nil
        }
        guard case .octetString(let communityData) = contents[1] else {
            SnmpError.debug("Expected community string, got \(contents[1])")
            return nil
        }
        let community = String(decoding: communityData, as: UTF8.self)
        guard community.count > 0 else {
            SnmpError.debug("Unable to decode community string from \(data)")
            return nil
        }
        self.community = community
        
        switch contents[2] {
        case .snmpResponse(let response):
            self.command = .getResponse
            self.requestId = response.requestId
            self.errorStatus = response.errorStatus
            self.errorIndex = response.errorIndex
            self.variableBindings = response.variableBindings
        default:
            SnmpError.debug("Expected SNMP response PDU, got \(contents[2])")
            return nil
        }
    }
}
