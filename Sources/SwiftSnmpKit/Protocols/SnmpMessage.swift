//
//  SnmpMessage.swift
//
//
//  Created by Adam Hitt on 12/12/23.
//

import Foundation



protocol SnmpMessage: AsnData {
    func requestID() -> Int32
    func varBinds() -> [SnmpVariableBinding]
    func errorStat() -> Int
    var version: SnmpVersion { get }
}
