import AVFoundation

protocol RTMPMuxerDelegate: AnyObject {
    func metadata(_ metadata: ASObject)
    func sampleOutput(audio buffer: Data, withTimestamp: Double, muxer: RTMPMuxer)
    func sampleOutput(video buffer: Data, withTimestamp: Double, muxer: RTMPMuxer)
}

// MARK: -
final class RTMPMuxer {
    static let aac: UInt8 = FLVAudioCodec.aac.rawValue << 4 | FLVSoundRate.kHz44.rawValue << 2 | FLVSoundSize.snd16bit.rawValue << 1 | FLVSoundType.stereo.rawValue

    weak var delegate: RTMPMuxerDelegate?
    private var configs: [Int: Data] = [:]
    private var audioTimeStamp = CMTime.zero
    private var videoTimeStamp = CMTime.zero

  //  Audioバッファ関連データ
  private var videoDifTime: Double = 0.0
  private var isFirstBuffering : Bool = true
  private var audioBufferingTime: Double = 0.0
  private var buffers : [Data?] = []
  private var deltas: [Double] = []
  private var bufferCount: Int = 0
  private let isAudioBuffering: Bool = true //  Audio Buffering機能ON/OFF

    func dispose() {
        configs.removeAll()
        audioTimeStamp = CMTime.zero
        videoTimeStamp = CMTime.zero

      //  Audioバッファデータ初期化
      initAudioBuffer()
    }
  deinit
  {
    print("deinit")
    initAudioBuffer()
  }
  
  /// Audioバッファデータ初期化
  private func initAudioBuffer() {
    videoDifTime = 0.0
    isFirstBuffering = true
    audioBufferingTime = 0.0
    buffers.removeAll()
    deltas.removeAll()
    bufferCount = 0
  }
}

extension RTMPMuxer: AudioCodecDelegate {
    // MARK: AudioCodecDelegate
    func audioCodec(_ codec: AudioCodec, didSet formatDescription: CMFormatDescription?) {
        guard let formatDescription = formatDescription else {
            return
        }
        var buffer = Data([RTMPMuxer.aac, FLVAACPacketType.seq.rawValue])
        buffer.append(contentsOf: AudioSpecificConfig(formatDescription: formatDescription).bytes)
        delegate?.sampleOutput(audio: buffer, withTimestamp: 0, muxer: self)
    }

    func audioCodec(_ codec: AudioCodec, didOutput sample: UnsafeMutableAudioBufferListPointer, presentationTimeStamp: CMTime) {
        let delta: Double = (audioTimeStamp == CMTime.zero ? 0 : presentationTimeStamp.seconds - audioTimeStamp.seconds) * 1000
        guard let bytes = sample[0].mData, 0 < sample[0].mDataByteSize && 0 <= delta else {
            return
        }
        var buffer = Data([RTMPMuxer.aac, FLVAACPacketType.raw.rawValue])
        buffer.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(sample[0].mDataByteSize))


      //  ライブ配信開始時にずれている場合だけを補正の対象とする
      //  何かと問題の多いアプリなので条件を限定して補正
//        if videoTimeStamp != .zero, videoDifTime == .zero {
        videoDifTime = presentationTimeStamp.seconds - videoTimeStamp.seconds
//        videoDifTime = 1.0
//        }
//      print("AudioTimeStamp: \(presentationTimeStamp.seconds),VideoTimeStamp: \(videoTimeStamp.seconds) difTime: \(presentationTimeStamp.seconds-videoTimeStamp.seconds) delta:\(delta/1000)")
/*
      if videoTimeStamp == .zero {
        return
      }
 */
      //  バッファリング機能OFF or 映像差分がdelta秒未満の場合はそのまま出力
      if !isAudioBuffering ||
          videoTimeStamp == .zero ||
          ((delta/1000) > videoDifTime && 0 == bufferCount ) {
        delegate?.sampleOutput(audio: buffer, withTimestamp: delta, muxer: self)
        audioTimeStamp = presentationTimeStamp
        print("AudioBuffer Not")
        if videoTimeStamp != .zero {
          //  初回バッファリングフラグOFF
          isFirstBuffering = false
        }
      }
      else {
        //  映像・音声の時間差を埋めるため音声データをバッファリング
        if videoTimeStamp == .zero || audioBufferingTime < videoDifTime {

          if 1.0 < audioBufferingTime {
            //  1秒以上になった場合は先頭データを消去後に最新データを追加
            buffers.removeFirst()
            deltas.removeFirst()
          }
          buffers.append(buffer)
          deltas.append(delta)
          bufferCount += 1

          delegate?.sampleOutput(audio: buffer, withTimestamp: delta, muxer: self)

          audioTimeStamp = presentationTimeStamp
          audioBufferingTime += (delta/1000)
          print("AudioBuffer Add: \(bufferCount)")

        } else {
//          print("AudioBufferCount: \(bufferCount)")
          //  初回バッファリングフラグOFF
          isFirstBuffering = false

          delegate?.sampleOutput(audio: buffers[0]!, withTimestamp: deltas[0], muxer: self)
          audioTimeStamp = presentationTimeStamp
          buffers.removeFirst()
          deltas.removeFirst()
          buffers.append(buffer)
          deltas.append(delta)
        }
      }

    }

  func isFirstBufferingAudio() -> Bool {
    return isFirstBuffering
  }
}

extension RTMPMuxer: VideoEncoderDelegate {
    // MARK: VideoEncoderDelegate
    func didSetFormatDescription(video formatDescription: CMFormatDescription?) {
        guard
            let formatDescription = formatDescription,
            let avcC = AVCConfigurationRecord.getData(formatDescription) else {
            return
        }
        var buffer = Data([FLVFrameType.key.rawValue << 4 | FLVVideoCodec.avc.rawValue, FLVAVCPacketType.seq.rawValue, 0, 0, 0])
        buffer.append(avcC)
        delegate?.sampleOutput(video: buffer, withTimestamp: 0, muxer: self)
    }

    func sampleOutput(video sampleBuffer: CMSampleBuffer) {
        let keyframe: Bool = !sampleBuffer.isNotSync
        var compositionTime: Int32 = 0
        let presentationTimeStamp: CMTime = sampleBuffer.presentationTimeStamp
        var decodeTimeStamp: CMTime = sampleBuffer.decodeTimeStamp
        if decodeTimeStamp == CMTime.invalid {
            decodeTimeStamp = presentationTimeStamp
        } else {
            compositionTime = Int32((presentationTimeStamp.seconds - decodeTimeStamp.seconds) * 1000)
        }
        let delta: Double = (videoTimeStamp == CMTime.zero ? 0 : decodeTimeStamp.seconds - videoTimeStamp.seconds) * 1000
        guard let data = sampleBuffer.dataBuffer?.data, 0 <= delta else {
            return
        }
//      print("video data sampleOutput delta:\(delta/1000)")
        var buffer = Data([((keyframe ? FLVFrameType.key.rawValue : FLVFrameType.inter.rawValue) << 4) | FLVVideoCodec.avc.rawValue, FLVAVCPacketType.nal.rawValue])
        buffer.append(contentsOf: compositionTime.bigEndian.data[1..<4])
        buffer.append(data)
        delegate?.sampleOutput(video: buffer, withTimestamp: delta, muxer: self)
        videoTimeStamp = decodeTimeStamp
    }
}
