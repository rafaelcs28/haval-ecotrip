import Foundation
import CoreBluetooth

/// Gerencia a conexão BLE com o adaptador ELM327.
///
/// ELM327 BLE clones (Vgate iCar Pro, OBDLink MX+, etc.) tipicamente expõem:
///   Service UUID:  FFE0 (alguns) ou 18F0 (OBDLink) ou customizado
///   Characteristic: FFE1 (TX/RX) ou 2AF0/2AF1 (OBDLink — separados)
///
/// Estratégia: escaneia por TODOS os service UUIDs conhecidos. Quando
/// conectar, descobre serviços e seleciona o primeiro characteristic que
/// suporta `.notify | .writeWithResponse | .writeWithoutResponse`.
final class BluetoothManager: NSObject, ObservableObject {
    enum State: String { case poweredOff, scanning, connecting, ready, error }

    @Published var state: State = .poweredOff
    @Published var lastResponse: String = ""
    @Published var deviceName: String = "—"
    @Published var rssi: Int = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxTxChar: CBCharacteristic?
    private var rxBuffer = ""
    private var pendingCallback: ((String) -> Void)?

    /// Service UUIDs conhecidos de adaptadores ELM327 BLE
    private let knownServices: [CBUUID] = [
        CBUUID(string: "FFE0"),     // genérico mais comum
        CBUUID(string: "FFF0"),     // alternativo
        CBUUID(string: "18F0"),     // OBDLink MX+
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),  // OBDII Bluetooth Pro
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        peripheral = nil; rxTxChar = nil; rxBuffer = ""
        state = .scanning
        // Scanear SEM filtrar por serviço (alguns clones não anunciam o serviço)
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .poweredOn == central.state ? .scanning : .error }
    }

    /// Envia comando ASCII (ex: "010C") com CR como terminador. ELM327
    /// responde no `peripheral:didUpdateValueFor:`. Callback dispara quando
    /// recebemos o prompt ">" indicando fim da resposta.
    func send(_ command: String, timeout: TimeInterval = 1.0, completion: @escaping (String) -> Void) {
        guard state == .ready, let p = peripheral, let c = rxTxChar else {
            completion(""); return
        }
        rxBuffer = ""
        pendingCallback = completion
        let payload = (command + "\r").data(using: .ascii)!
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(payload, for: c, type: type)
        // Timeout — se não responder dentro do prazo, fecha pendente com vazio
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            if let cb = self.pendingCallback {
                self.pendingCallback = nil
                cb(self.rxBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:  if state == .poweredOff { state = .poweredOff /* aguarda startScan */ }
        case .poweredOff: state = .poweredOff
        default:          state = .error
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Heurística: nome contém "OBD", "Vgate", "ELM", "ICAR"
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let upper = name.uppercased()
        let isObd = upper.contains("OBD") || upper.contains("VGATE") || upper.contains("ELM") ||
                    upper.contains("ICAR") || upper.contains("OBDII") || upper.contains("327")
        if !isObd { return }
        deviceName = name
        rssi = RSSI.intValue
        // Conecta no primeiro candidato
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .poweredOff
        rxTxChar = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startScan()  // tenta reconectar
        }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            // Seleciona o primeiro que suporta notify + write
            let canNotify = c.properties.contains(.notify) || c.properties.contains(.indicate)
            let canWrite  = c.properties.contains(.write)  || c.properties.contains(.writeWithoutResponse)
            if canNotify && canWrite {
                rxTxChar = c
                peripheral.setNotifyValue(true, for: c)
                state = .ready
                return
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let str = String(data: data, encoding: .ascii) else { return }
        rxBuffer += str
        if str.contains(">") {
            // Prompt — fim da resposta
            let payload = rxBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            lastResponse = payload
            if let cb = pendingCallback {
                pendingCallback = nil
                cb(payload)
            }
            rxBuffer = ""
        }
    }
}
