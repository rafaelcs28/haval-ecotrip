import Foundation
import CoreBluetooth

/// Gerencia a conexão BLE com o adaptador ELM327.
///
/// Suporta vários padrões de characteristics conhecidos:
///   • Service FFE0 + char FFE1  (clones genéricos, Vgate iCar Pro)
///   • Service 18F0 + chars 2AF0 (notify) + 2AF1 (write)  (Veepeak novo)
///   • Service customizado com pares notify/write separados
///
/// Estratégia robusta:
///   1. Lista TODAS as services + characteristics descobertas
///   2. Prefere UUIDs conhecidos
///   3. Aceita rx/tx em characteristics separadas (não exige notify+write juntos)
final class BluetoothManager: NSObject, ObservableObject {
    enum State: String { case poweredOff, scanning, connecting, ready, error }

    @Published var state: State = .poweredOff
    @Published var lastResponse: String = ""
    @Published var deviceName: String = "—"
    @Published var rssi: Int = 0
    @Published var nearbyDevices: [(name: String, rssi: Int, id: UUID)] = []
    /// Log dos últimos 20 comandos enviados + respostas — visível na UI
    @Published var commandLog: [(t: Date, dir: String, text: String)] = []
    /// Lista de characteristics descobertas — útil pra debug
    @Published var debugChars: [String] = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?   // notify (recebe)
    private var txChar: CBCharacteristic?   // write (envia)
    private var rxBuffer = ""
    private var pendingCallback: ((String) -> Void)?

    /// UUIDs conhecidos de adaptadores ELM327 BLE — preferidos quando aparecem
    private let preferredCharUUIDs: [CBUUID] = [
        CBUUID(string: "FFE1"),       // genérico
        CBUUID(string: "FFF1"),       // alternativo
        CBUUID(string: "2AF0"),       // Veepeak BLE+ notify
        CBUUID(string: "2AF1"),       // Veepeak BLE+ write
        CBUUID(string: "ABF1"),       // OBDLink
        CBUUID(string: "ABF2"),       // OBDLink alt
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func log(_ dir: String, _ text: String) {
        DispatchQueue.main.async {
            self.commandLog.append((t: Date(), dir: dir, text: text))
            if self.commandLog.count > 20 { self.commandLog.removeFirst() }
        }
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        peripheral = nil; rxChar = nil; txChar = nil; rxBuffer = ""
        nearbyDevices.removeAll(); debugChars.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self else { return }
            if self.state == .scanning {
                self.central.stopScan()
                if self.nearbyDevices.isEmpty {
                    self.deviceName = "Nenhum dispositivo BLE encontrado"
                } else {
                    self.deviceName = "ELM327 não detectado — \(self.nearbyDevices.count) próximos"
                }
                self.state = .poweredOff
            }
        }
    }

    func connectManually(id: UUID) {
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            central.stopScan()
            self.peripheral = p
            p.delegate = self
            state = .connecting
            deviceName = p.name ?? "Manual"
            central.connect(p, options: nil)
        }
    }

    /// Envia comando ELM327 (AT ou PID hex). Termina com \r. Aguarda prompt ">"
    /// como fim da resposta. Timeout default 1s — ATZ precisa de mais (5s).
    func send(_ command: String, timeout: TimeInterval = 1.0, completion: @escaping (String) -> Void) {
        guard state == .ready, let p = peripheral, let c = txChar else {
            log("ERR", "send sem ready ou txChar")
            completion(""); return
        }
        rxBuffer = ""
        pendingCallback = completion
        log("→", command)
        let payload = (command + "\r").data(using: .ascii)!
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        p.writeValue(payload, for: c, type: type)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            if let cb = self.pendingCallback {
                self.pendingCallback = nil
                let resp = self.rxBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                self.log("←", resp.isEmpty ? "(timeout)" : resp)
                cb(resp)
            }
        }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { state = .poweredOff }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let display = name.isEmpty ? "(sem nome)" : name
        if !nearbyDevices.contains(where: { $0.id == peripheral.identifier }) {
            nearbyDevices.append((name: display, rssi: RSSI.intValue, id: peripheral.identifier))
            nearbyDevices.sort { $0.rssi > $1.rssi }
        }
        let upper = name.uppercased()
        let isObd = upper.contains("OBD") || upper.contains("VGATE") || upper.contains("ELM") ||
                    upper.contains("ICAR") || upper.contains("327") ||
                    upper.contains("VLINK") || upper.contains("VEEPEAK")
        if !isObd { return }
        deviceName = name
        rssi = RSSI.intValue
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("BT", "conectado · descobrindo serviços")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error
        log("ERR", "falha de conexão: \(error?.localizedDescription ?? "?")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .poweredOff
        rxChar = nil; txChar = nil
        log("BT", "desconectado: \(error?.localizedDescription ?? "OK")")
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        log("BT", "\(services.count) serviços encontrados")
        for s in services {
            log("BT", "service \(s.uuid)")
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            let canNotify = c.properties.contains(.notify) || c.properties.contains(.indicate)
            let canWrite  = c.properties.contains(.write)  || c.properties.contains(.writeWithoutResponse)
            let flags = "\(canNotify ? "N" : "-")\(canWrite ? "W" : "-")"
            let desc = "\(c.uuid) [\(flags)]"
            DispatchQueue.main.async { self.debugChars.append(desc) }
            log("BT", "char \(desc)")
        }
        // Estratégia de seleção:
        //   1. Se UUID está nos preferred — assume papel apropriado
        //   2. Se não, usa heurística por properties
        for c in chars {
            let isPreferred = preferredCharUUIDs.contains(c.uuid)
            let canNotify = c.properties.contains(.notify) || c.properties.contains(.indicate)
            let canWrite  = c.properties.contains(.write)  || c.properties.contains(.writeWithoutResponse)
            // Caso 1: characteristic faz AMBOS — ideal pra clones genéricos
            if canNotify && canWrite {
                rxChar = c; txChar = c
                peripheral.setNotifyValue(true, for: c)
                log("BT", "rx+tx: \(c.uuid)")
                break
            }
            // Caso 2: notify só — vai ser rx
            if canNotify && rxChar == nil {
                rxChar = c
                peripheral.setNotifyValue(true, for: c)
                log("BT", "rx: \(c.uuid)")
            }
            // Caso 3: write só — vai ser tx
            if canWrite && txChar == nil {
                txChar = c
                log("BT", "tx: \(c.uuid)")
            }
            _ = isPreferred  // (poderia priorizar — não complica pro MVP)
        }
        if rxChar != nil && txChar != nil && state != .ready {
            state = .ready
            log("BT", "pronto · rx + tx mapeados")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let str = String(data: data, encoding: .ascii) else { return }
        rxBuffer += str
        if str.contains(">") {
            let payload = rxBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            lastResponse = payload
            log("←", payload)
            if let cb = pendingCallback {
                pendingCallback = nil
                cb(payload)
            }
            rxBuffer = ""
        }
    }
}
