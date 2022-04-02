import MetalKit
import AVFoundation
import CoreVideo
import PhotosUI
@available(iOS 11.0, *)
public class RGBD {
    private var textureCache: CVMetalTextureCache?
    private var metalDevice: MTLDevice!
    private var generator:AVAssetImageGenerator!
    public init() {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        var metalTextureCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
            assertionFailure("Unable to allocate depth converter texture cache")
        } else {
            textureCache = metalTextureCache
        }
    }
    
    /**
        function to load CIImage as different type.
     **/
    
    func pixelBufferFromCGImage(cgImage: CGImage, format: OSType) -> CVPixelBuffer {
        var pxbuffer: CVPixelBuffer? = nil
        let options: NSDictionary = [:]

        let width =  cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow

        let dataFromImageDataProvider = CFDataCreateMutableCopy(kCFAllocatorDefault, 0, cgImage.dataProvider!.data)
        let x = CFDataGetMutableBytePtr(dataFromImageDataProvider)!

        CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            width,
            height,
            format,
            x,
            bytesPerRow,
            nil,
            nil,
            options,
            &pxbuffer
        )
        return pxbuffer!;
    }
    func PixelBufferToMTLTexture(pixelBuffer:CVPixelBuffer, format: MTLPixelFormat) -> MTLTexture?
    {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // Create a Metal texture from the image buffer
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                  textureCache!,
                                                  pixelBuffer,
                                                  nil,
                                                  format,
                                                  width,
                                                  height,
                                                  0,
                                                  &cvTextureOut)
        guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
            print("Depth converter failed to create preview texture")
            CVMetalTextureCacheFlush(textureCache!, 0)
            return nil
        }

        return texture
    }
    
    /**
        parse data as jpeg/png representation using cgImage.
     **/
    func savePhotoToLibrary(data: Data){
        PHPhotoLibrary.shared().performChanges({
            let options = PHAssetResourceCreationOptions()
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: data, options: options)
            }, completionHandler: { success, error in
                if !success {
                    print("Couldn't save the photo to your photo library: \(String(describing: error))")
                }else{
                    print("photo saved!")
                }
            })
    }
    func loadPhotoFromLocal(name: String, fileExtension: String)->UIImage?{
        guard let filePath = Bundle.main.path(forResource: name, ofType: fileExtension) else {print("invalid file path"); return nil}
        guard let image = UIImage(contentsOfFile: filePath) else {print("unable to load images");return nil}
        return image
    }
    
    /**
        function to save an array of UIImage to iPhone photo library.
     **/
    func saveVideoToLibrary(videoURL: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }) { saved, error in
            
            if let error = error {
                print("Error saving video to librayr: \(error.localizedDescription)")
            }
            if saved {
                print("Video save to library")
                
            }
        }
    }
    func buildVideoFromImageArray(framesArray:[UIImage]) {
        var images = framesArray
        let outputSize = CGSize(width:images[0].size.width, height: images[0].size.height)
        let fileManager = FileManager.default
        let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        guard let documentDirectory = urls.first else {
            fatalError("documentDir Error")
        }
        
        let videoOutputURL = documentDirectory.appendingPathComponent("OutputVideo.mp4")
        
        if FileManager.default.fileExists(atPath: videoOutputURL.path) {
            do {
                try FileManager.default.removeItem(atPath: videoOutputURL.path)
            } catch {
                fatalError("Unable to delete file: \(error) : \(#function).")
            }
        }
        
        guard let videoWriter = try? AVAssetWriter(outputURL: videoOutputURL, fileType: AVFileType.mp4) else {
            fatalError("AVAssetWriter error")
        }
        
        let outputSettings = [AVVideoCodecKey : AVVideoCodecType.h264, AVVideoWidthKey : NSNumber(value: Float(outputSize.width)), AVVideoHeightKey : NSNumber(value: Float(outputSize.height))] as [String : Any]
        
        guard videoWriter.canApply(outputSettings: outputSettings, forMediaType: AVMediaType.video) else {
            fatalError("Negative : Can't apply the Output settings...")
        }
        
        let videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: outputSettings)
        let sourcePixelBufferAttributesDictionary = [
            kCVPixelBufferPixelFormatTypeKey as String : NSNumber(value: kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: NSNumber(value: Float(outputSize.width)),
            kCVPixelBufferHeightKey as String: NSNumber(value: Float(outputSize.height))
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput, sourcePixelBufferAttributes: sourcePixelBufferAttributesDictionary)
        
        if videoWriter.canAdd(videoWriterInput) {
            videoWriter.add(videoWriterInput)
        }
        
        if videoWriter.startWriting() {
            videoWriter.startSession(atSourceTime: CMTime.zero)
            assert(pixelBufferAdaptor.pixelBufferPool != nil)
            
            let media_queue = DispatchQueue(__label: "mediaInputQueue", attr: nil)
            
            videoWriterInput.requestMediaDataWhenReady(on: media_queue, using: { () -> Void in
                let fps: Int32 = 30//2
                let frameDuration = CMTimeMake(value: 1, timescale: fps)
                
                var frameCount: Int64 = 0
                var appendSucceeded = true
                
                while (!images.isEmpty) {
                    if (videoWriterInput.isReadyForMoreMediaData) {
                        let nextPhoto = images.remove(at: 0)
                        let lastFrameTime = CMTimeMake(value: frameCount, timescale: fps)
                        let presentationTime = frameCount == 0 ? lastFrameTime : CMTimeAdd(lastFrameTime, frameDuration)
                        
                        var pixelBuffer: CVPixelBuffer? = nil
                        let status: CVReturn = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferAdaptor.pixelBufferPool!, &pixelBuffer)
                        
                        if let pixelBuffer = pixelBuffer, status == 0 {
                            let managedPixelBuffer = pixelBuffer
                            
                            CVPixelBufferLockBaseAddress(managedPixelBuffer, [])
                            
                            let data = CVPixelBufferGetBaseAddress(managedPixelBuffer)
                            let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
                            let context = CGContext(data: data, width: Int(outputSize.width), height: Int(outputSize.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(managedPixelBuffer), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
                            
                            context?.clear(CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height))
                            
                            let horizontalRatio = CGFloat(outputSize.width) / nextPhoto.size.width
                            let verticalRatio = CGFloat(outputSize.height) / nextPhoto.size.height
                            
                            let aspectRatio = min(horizontalRatio, verticalRatio) // ScaleAspectFit
                            
                            let newSize = CGSize(width: nextPhoto.size.width * aspectRatio, height: nextPhoto.size.height * aspectRatio)
                            
                            let x = newSize.width < outputSize.width ? (outputSize.width - newSize.width) / 2 : 0
                            let y = newSize.height < outputSize.height ? (outputSize.height - newSize.height) / 2 : 0
                            
                            context?.draw(nextPhoto.cgImage!, in: CGRect(x: x, y: y, width: newSize.width, height: newSize.height))
                            
                            CVPixelBufferUnlockBaseAddress(managedPixelBuffer, [])
                            
                            appendSucceeded = pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                            frameCount += 1
                        } else {
                            print("Failed to allocate pixel buffer")
                            appendSucceeded = false
                        }
                    }
                    if !appendSucceeded {
                        break
                    }
                    //frameCount += 1
                }
                videoWriterInput.markAsFinished()
                videoWriter.finishWriting { () -> Void in
                    print("Done saving")
                    self.saveVideoToLibrary(videoURL: videoOutputURL)
                }
            })
        }
    }
    func loadVideoFromLocal(filename: String, fileExtension: String)->[UIImage]? {
        guard let url = Bundle.main.url(forResource: filename, withExtension: fileExtension) else{print("unable to load URL"); return nil}
        let asset:AVAsset = AVAsset(url:url)
        let duration:Float64 = CMTimeGetSeconds(asset.duration)
        self.generator = AVAssetImageGenerator(asset:asset)
        self.generator.appliesPreferredTrackTransform = true
        var frames: [UIImage] = []
        for index:Int in 0 ..< Int(duration) {
            let time:CMTime = CMTimeMakeWithSeconds(Float64(index), preferredTimescale:600)
            let image:CGImage
            do {
               try image = self.generator.copyCGImage(at:time, actualTime:nil)
            } catch {
               return nil
            }
            frames.append(UIImage(cgImage:image))
        }
        self.generator = nil
        return frames
    }
    /**
        convert depth CVPixelBuffer to flat array.
     **/
    func convertDepthDataToFloatArray(depthDataMap: CVPixelBuffer) -> [[Float32]]{
        let width: Int = CVPixelBufferGetWidth(depthDataMap)
        let height: Int = CVPixelBufferGetHeight(depthDataMap)
        var convertedDepthMap: [[Float32]] = Array(
            repeating: Array(repeating: 0, count: width),
            count: height
        )
        CVPixelBufferLockBaseAddress(depthDataMap, CVPixelBufferLockFlags(rawValue: 2))
        let floatBuffer = unsafeBitCast(
            CVPixelBufferGetBaseAddress(depthDataMap),
            to: UnsafeMutablePointer<Float32>.self)
        for row in 0..<height{
            for col in 0..<width{
                convertedDepthMap[row][col] = floatBuffer[width * row + col]
            }
        }
        CVPixelBufferUnlockBaseAddress(depthDataMap, CVPixelBufferLockFlags(rawValue: 2))
        
        return convertedDepthMap
    }
    func convertFloatArrayToDepthData(depthData: [[Float32]], width: Int, height: Int) -> CVPixelBuffer?{
        var depthDataArray = depthData
        var depthBuffer: CVPixelBuffer? = nil
        let options: NSDictionary = [:]

        CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_DepthFloat32,
            &depthDataArray,
            MemoryLayout<Float32>.stride*640,
            nil,
            nil,
            options,
            &depthBuffer
        )
        return depthBuffer
    }
}
