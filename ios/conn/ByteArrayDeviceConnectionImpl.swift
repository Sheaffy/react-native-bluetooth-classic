//
//  ByteArrayDeviceConnectionImpl.swift
//  react-native-bluetooth-classic
//
//  Created by Sheaffy on 2025-06-26.
//

import Foundation
import ExternalAccessory

/**
 * Implements `DeviceConnection` to provide direct writing and reading of `Data` (byte[]).
 * When writing, `Data` is transferred as is. When data is received, it's collected in
 * an internal buffer. A `read()` operation returns the entire buffer, Base64 encoded,
 * and then clears it.
 *
 * This implementation uses the `read_size` property from the connection options to
 * determine the buffer size for reading from the input stream, defaulting to 1024.
 *
 * @author kendavidson
 */
class ByteArrayDeviceConnectionImpl : NSObject, DeviceConnection, StreamDelegate {

    // A serial dispatch queue to synchronize access to the inBuffer and outBuffer.
    private let bufferQueue = DispatchQueue(label: "com.kjd.reactnative.bluetooth.classic.byte.buffer")

    /// The delegate to be notified when data is received from the accessory.
    private var _dataReceivedDelegate: DataReceivedDelegate?
    var dataReceivedDelegate: DataReceivedDelegate? {
        set(newDelegate) {
            // When a new delegate is set, we check if there's any data
            // already in the buffer. If so, we deliver it immediately.
            var dataToSend: String?
            bufferQueue.sync {
                self._dataReceivedDelegate = newDelegate
                if newDelegate != nil && !self.inBuffer.isEmpty {
                    dataToSend = self.inBuffer.base64EncodedString()
                    self.inBuffer.removeAll()
                }
            }
            
            if let data = dataToSend, let delegate = newDelegate {
                 DispatchQueue.main.async {
                    delegate.onReceivedData(fromDevice: self.accessory, receivedData: data)
                }
            }
        }
        get {
            return bufferQueue.sync { self._dataReceivedDelegate }
        }
    }

    /// The active EASession for communication with the accessory.
    private var session: EASession?
    
    /// Buffers for incoming and outgoing data. Access must be synchronized via bufferQueue.
    private var inBuffer: Data
    private var outBuffer: Data

    /// The connected External Accessory.
    private(set) var accessory: EAAccessory
    
    /// Configuration properties for the connection.
    private(set) var properties: Dictionary<String,Any>

    /// The maximum number of bytes to read from the stream at one time.
    private var readSize: Int

    /**
     * Initializes a new byte array connection.
     *
     * - parameter accessory: The `EAAccessory` to connect to.
     * - parameter options: A dictionary of options for the connection.
     * Supported options: `read_size`.
     */
    init(
        accessory: EAAccessory,
        options: Dictionary<String,Any>
    ) {
        self.accessory = accessory
        self.properties = options
        self.inBuffer = Data()
        self.outBuffer = Data()

        // Determine the read size from the provided options, with a default value.
        // This checks for both casing styles for flexibility.
        var tempReadSize: Int?
        if let value = options["READ_SIZE"] as? Int {
            tempReadSize = value
        } else if let value = options["read_size"] as? Int {
            tempReadSize = value
        }
        self.readSize = tempReadSize ?? 1024
        
        super.init()
    }

    /**
     * Establishes a connection to the accessory by opening an `EASession` and its
     * corresponding input and output streams.
     *
     * - throws: `BluetoothError.CONNECTION_FAILED` if the session cannot be established.
     */
    func connect() throws {
        guard let protocolString = self.properties["PROTOCOL_STRING"] as? String else {
            NSLog("(ByteArrayDeviceConnection) Error: PROTOCOL_STRING not found in properties")
            throw BluetoothError.CONNECTION_FAILED
        }

        NSLog("(ByteArrayDeviceConnection:connect) Attempting connection to %@ using protocol %@", accessory.serialNumber, protocolString)
        if let newSession = EASession(accessory: accessory, forProtocol: protocolString) {
            self.session = newSession

            // Configure and open the streams for communication.
            if let inStream = newSession.inputStream, let outStream = newSession.outputStream {
                inStream.delegate = self
                outStream.delegate = self
                inStream.schedule(in: .main, forMode: RunLoopMode.defaultRunLoopMode)
                outStream.schedule(in: .main, forMode: RunLoopMode.defaultRunLoopMode)
                inStream.open()
                outStream.open()
            }
        } else {
            NSLog("(ByteArrayDeviceConnection:connect) Failed to create EASession")
            throw BluetoothError.CONNECTION_FAILED
        }
    }

    /**
     * Disconnects from the accessory by closing the streams and session.
     */
    func disconnect() {
        NSLog("(ByteArrayDeviceConnection:disconnect) Disconnecting from %@", accessory.serialNumber)
        if let currentSession = session {
            currentSession.inputStream?.close()
            currentSession.inputStream?.remove(from: .main, forMode: RunLoopMode.defaultRunLoopMode)
            currentSession.outputStream?.close()
            currentSession.outputStream?.remove(from: .main, forMode: RunLoopMode.defaultRunLoopMode)
        }
        session = nil
        clear()
    }

    /**
     * Returns the number of bytes currently available in the input buffer.
     *
     * - returns: The number of available bytes.
     */
    func available() -> Int {
        return bufferQueue.sync { inBuffer.count }
    }

    /**
     * Schedules data to be sent to the accessory. The data is placed in an
     * output buffer and written to the stream when space is available.
     *
     * - parameter data: The `Data` object to be sent.
     * - returns: `true` if the data was successfully scheduled for writing.
     */
    func write(_ data: Data) -> Bool {
        NSLog("(ByteArrayDeviceConnection:write) Scheduling %d bytes to write to %@", data.count, accessory.serialNumber)
        bufferQueue.async {
            self.outBuffer.append(data)
        }
        
        // Trigger an immediate write attempt if the output stream is available.
        if let stream = session?.outputStream, stream.hasSpaceAvailable {
            writeDataToStream(stream)
        }

        return true
    }

    /**
     * Reads the entire contents of the input buffer, encodes it as a Base64 string,
     * and clears the input buffer. This is a thread-safe operation.
     *
     * - returns: A Base64 encoded string of the buffer's contents, or `nil` if the buffer is empty.
     */
    func read() -> String? {
        return bufferQueue.sync {
            if inBuffer.isEmpty {
                return nil
            }
            
            NSLog("(ByteArrayDeviceConnection:read) Reading %d bytes from device %@", inBuffer.count, accessory.serialNumber)

            let base64String = inBuffer.base64EncodedString()
            inBuffer.removeAll() // Only clear the input buffer.

            return base64String
        }
    }

    /**
     * Clears both the input and output buffers in a thread-safe manner.
     */
    func clear() {
        bufferQueue.async {
            self.inBuffer.removeAll()
            self.outBuffer.removeAll()
        }
    }

    /**
     * Handles events from the input and output streams.
     */
    @objc
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch(eventCode) {
        case .openCompleted:
            NSLog("(ByteArrayDeviceConnection:stream) Stream opened: %@", aStream)
            break
        case .hasBytesAvailable:
            NSLog("(ByteArrayDeviceConnection:stream) Stream has bytes available: %@", aStream)
            if let stream = aStream as? InputStream {
                readDataFromStream(stream)
            }
            break
        case .hasSpaceAvailable:
            NSLog("(ByteArrayDeviceConnection:stream) Stream has space available: %@", aStream)
            if let stream = aStream as? OutputStream {
                writeDataToStream(stream)
            }
            break
        case .errorOccurred:
            NSLog("(ByteArrayDeviceConnection:stream) Error occurred on stream: %@, Error: %@", aStream, aStream.streamError?.localizedDescription ?? "N/A")
            break
        case .endEncountered:
            NSLog("(ByteArrayDeviceConnection:stream) Stream end encountered: %@", aStream)
            disconnect()
            break
        default:
            NSLog("(ByteArrayDeviceConnection:stream) Unknown stream event: %@", aStream)
        }
    }

    /**
     * Reads available data from the input stream into the `inBuffer` and notifies the delegate.
     * This operation is made thread-safe by synchronizing buffer access.
     */
    private func readDataFromStream(_ stream: InputStream) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: readSize)
        defer { buffer.deallocate() }

        var dataWasRead = false
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: readSize)
            if bytesRead <= 0 {
                if let error = stream.streamError {
                     NSLog("(ByteArrayDeviceConnection:readData) Stream read error: %@", error.localizedDescription)
                }
                break
            }
            
            bufferQueue.sync {
                inBuffer.append(buffer, count: bytesRead)
            }
            dataWasRead = true
        }
        
        // If a delegate is listening and we read data, process and send it.
        var dataForDelegate: String?
        if dataWasRead {
             bufferQueue.sync {
                if self._dataReceivedDelegate != nil && !self.inBuffer.isEmpty {
                    dataForDelegate = self.inBuffer.base64EncodedString()
                    self.inBuffer.removeAll()
                }
             }
        }
       
        if let data = dataForDelegate, let delegate = self.dataReceivedDelegate {
            DispatchQueue.main.async {
                delegate.onReceivedData(fromDevice: self.accessory, receivedData: data)
            }
        }
    }

    /**
     * Writes data from the `outBuffer` to the output stream. The buffer access and modification
     * is performed atomically to prevent race conditions.
     */
    private func writeDataToStream(_ stream: OutputStream) {
        bufferQueue.async {
            guard !self.outBuffer.isEmpty else {
                return
            }
            
            let bytesWritten = self.outBuffer.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                let bytesToWrite = min(self.outBuffer.count, self.readSize)
                guard let baseAddress = ptr.baseAddress else { return 0 }
                return stream.write(baseAddress.assumingMemoryBound(to: UInt8.self), maxLength: bytesToWrite)
            }

            if bytesWritten > 0 {
                // This is now safe because the read (withUnsafeBytes) and the write (removeFirst)
                // happen within the same synchronized block, preventing other threads from
                // modifying the buffer in between.
                self.outBuffer.removeFirst(bytesWritten)
                NSLog("(ByteArrayDeviceConnection:writeData) Wrote %d bytes to stream. %d bytes remaining.", bytesWritten, self.outBuffer.count)
            } else if let error = stream.streamError {
                NSLog("(ByteArrayDeviceConnection:writeData) Stream write error: %@", error.localizedDescription)
            }
        }
    }
}

/**
 * A factory for creating `ByteArrayDeviceConnectionImpl` instances.
 */
class ByteArrayDeviceConnectionFactory : DeviceConnectionFactory {
    func create(accessory: EAAccessory, options: Dictionary<String, Any>) -> DeviceConnection {
        return ByteArrayDeviceConnectionImpl(accessory: accessory, options: options)
    }
}