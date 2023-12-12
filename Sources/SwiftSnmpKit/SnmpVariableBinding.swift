//
//  File 2.swift
//  
//
//  Created by Darrell Root on 6/30/22.
//

import Foundation
/// A SNMP variable binding includes an OID and the value.
/// The value is ASN.1 encoded.
/// The MIB files explain the value for the OID, but SwiftSnmpKit does not
/// currently analyze the MIB files.
public struct SnmpVariableBinding: Equatable, CustomStringConvertible {
    public private(set) var oid: SnmpOid
    public internal(set) var value: AsnValue // internal setter only used for test cases, treat as private
    
    /// This is used to create a varaible binding for a SNMP Request.  The value of the binding is automatically set to null.
    /// - Parameter oid: The OID to be requested
    init(oid: SnmpOid) {
        self.oid = oid
        self.value = AsnValue.null
    }
    
    /// This decodes incoming network data into a variable binding
    /// - Parameter data: Data as received over the network in a SNMP reply
    init(data: Data) throws {
        let objectName = try AsnValue(data: data)
        _ = try AsnValue.pduLength(data: data)
        guard case .sequence(let sequence) = objectName else {
            SnmpError.log("Expected Sequence got \(objectName)")
            throw SnmpError.unexpectedSnmpPdu
        }
        guard sequence.count == 2 else {
            SnmpError.log("Expected sequence containing two values got \(sequence)")
            throw SnmpError.unexpectedSnmpPdu
        }
        let oidValue = sequence[0]
        guard case .oid(let oid) = oidValue else {
            SnmpError.log("Expected OID got \(oidValue)")
            throw SnmpError.unexpectedSnmpPdu
        }
        self.oid = oid
        let value = sequence[1]
        //let value = try AsnValue(data: data[(data.startIndex+nameLength)...])
        self.value = value
    }
    /// A printout of the OID and the value
    public var description: String {
        return "\(oid): \(value)"
    }
    internal var asn: AsnValue {
        return AsnValue.sequence([self.oid.asn,self.value])
    }
    internal var asnData: Data {
        return self.asn.asnData
    }
}

// this extension intended only to support test cases
extension SnmpVariableBinding {
    internal mutating func setValue(_ value: AsnValue) {
        self.value = value
    }
}
