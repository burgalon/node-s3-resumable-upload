Stream = require('stream')

class ChunkedStream extends Stream
  # http://docs.amazonwebservices.com/AmazonS3/latest/API/mpUploadListParts.html
  MAX_PARTS: 1000
  readable: true
  writable: false
  chunkSize: 6291456
  # Total number of chunks to be uploaded
  totalChunkNumber: null
  # Current chunk number which is being uploaded
  chunkNumber: null
  writtenChunkSize: 0
  # How many bytes were written to S3 up until 'now'
  totalWriteSize: 0
  didOnEnd: false

  # Helps determine if the original source stream was actually done. See handleS3Response() function
  readStreamEnded: false

  # Amazon uploadId provided when initUpload is called
  uploadId: null

  ###
    https://github.com/SaltwaterC/aws2js/wiki/s3.completeUpload%28%29
    Structure:
    [
     1: '"etag-for-part-1"',
     2: '"etag-for-part-2"',
     [...]
     n: '"etag-for-part-n"'
    ]
  ###
  uploadParts: null

  # static functions
  @get: (s3, path, callback) ->

  # chunkNumber is counted from 1+
  constructor: (@s3, @path, @cannedAcl, @headers, @callback, @chunkNumber=1) ->
    @log 'constructor'
    @uploadParts = {}
    @contentLength  = @headers['content-length'] || 0
    @totalChunkNumber = Math.ceil(@contentLength / @chunkSize)

    # Content-Range: bytes <first_byte>-<last_byte>/<total_content_length>
    # https://developers.google.com/youtube/2.0/developers_guide_protocol_resumable_uploads
    contentRange  = @headers['content-range']
    if contentRange
      delete @headers['content-range']
      return @resumeUpload(contentRange)

    headers = @headers
    delete headers['content-length']

    # Check that there's body
    unless @contentLength
      return @callbackBadRequest('Content-Length missing or zero')

    s3.initUpload(@path, @cannedAcl, @headers, @initUploadCallback)

  resumeUpload: (contentRange) ->
    @log 'resumeUpload', contentRange


    pathParts = @path.split('/')
    bucketName = pathParts.shift()
    objectKey = pathParts.join('|')

    # Client is querying which bits/bytes/range are in the system
    if contentRange == 'bytes */*'
      @chunkNumber = @MAX_PARTS
      @totalChunkNumber = '*'
      return @s3.get(bucketName + '?uploads', prefix: objectKey, 'xml', @listUploadsCallback)

    matches = contentRange.match(/^bytes (\d+)\-(\d+)\/(\d+)$/)

    # Content range format must be correct
    if !matches
      return @callbackBadRequest("Content-Range headers should be of the form: Content-Range: bytes <first_byte>-<last_byte>/<total_content_length>")
    [all, firstByte, lastByte, totalContentLength] = matches

    # Must start uploading from the first byte of a chunk
    if firstByte % @chunkSize != 0
      return @callbackBadRequest("Content-Range first_byte should be a multiply of chunk size #{@chunkSize}.")

    # Must upload entire chunks
    if lastByte % @chunkSize != 0 && lastByte != totalContentLength
      return @callbackBadRequest("Content-Range last_byte should be a multiply of chunk size #{@chunkSize} or total_content_length #{totalContentLength}. Given #{lastByte}")

    @totalChunkNumber = Math.ceil(totalContentLength / @chunkSize)
    @chunkNumber = (firstByte / @chunkSize) + 1

    # List existing uploads for this key (=determine uploadID)
    # http://docs.amazonwebservices.com/AmazonS3/latest/API/mpUploadListMPUpload.html
    # s3.get(path, query, handler, callback)
    @s3.get(bucketName + '?uploads', prefix: objectKey, 'xml', @listUploadsCallback)

  listUploadsCallback: (error, result) =>
    @log 'listUploadsCallback'
    if error
      @log 'listUploadsCallback error', error
      # Call original callback with error
      @callback error, result

    if !result.Upload? || result.Upload.length==0
      return @callbackBadRequest("Could not find upload to resume. Use GET request to determine the state of your upload.")

    if result.Upload.length > 1
      @log "WARNING: Found #{result.Upload.length} pending uploads for the same key (#{@path}). Taking first object"

    # If there's one chunk, the XML serializer just puts the first object
    if result.Upload instanceof Array
      uploadObject = result.Upload[0]
    else
      uploadObject = result.Upload

    # Get which chunks/parts were already uploaded
    # http://docs.amazonwebservices.com/AmazonS3/latest/API/mpUploadListParts.html
    @s3.get(@path, uploadId: uploadObject.UploadId, 'max-parts': @MAX_PARTS, 'xml', @listPartsCallback)


  listPartsCallback: (error, result) =>
    @log 'listPartsCallback'
    if error
      @log 'listUploadsCallback error', error
      # Call original callback with error
      @callback error, result

    if result.Part?
      # If there's one chunk, the XML serializer just puts the first object
      unless result.Part instanceof Array
        result.Part = [result.Part]
    else
      # If there are NO parts
      result.Part = []

    partsHash = {}
    for key, part of result.Part
      @uploadParts[part.PartNumber] = part.ETag
      partsHash[part.PartNumber] = part

    # Make sure that all chunks up until chunkNumber exist
    uploadedBytes = 0
    @log 'checking parts', @chunkNumber
    for i in [1...@chunkNumber]
      unless @uploadParts[i]?
        # In case the client is querying which bits/bytes/range are in the system
        if @totalChunkNumber=='*'
          @log "Queried object #{@path} #{uploadedBytes}"
          # uploadedBytes since the range of bytes that we have is -1 the size of the object
          # i.e: If we have a file with size=2 bytes ==> We have byte range 0-1
          # Range is 0-based index
          return @callback(code: 308, headers: {'Range': "0-#{uploadedBytes-1}"})

        # Else
        @log "could not find chunk #{i}. uploadParts", @uploadParts
        return @callbackBadRequest("Missing chunk #{i}. Tried to resume from chunk #{@chunkNumber}")
      uploadedBytes += parseInt(partsHash[i].Size)

    # Start uploading
    @uploadId = result.UploadId
    @writable = true
    @doStream()

  # Start uploading one chunk
  doStream: ->
    @log "doStream - starting new chunk.", @chunkNumber, @writtenChunkSize, '/', @chunkSize, ' | ', @totalWriteSize, '/', @contentLength

    # Last chunk size?
    if @contentLength-@totalWriteSize<=@chunkSize
      contentLength = @contentLength-@totalWriteSize
    else
      contentLength = @chunkSize

    # s3.putStreamPart(path, partNumber, uploadId, stream, headers, callback)
    s3request = @s3.putStreamPart(
      @path,
      @chunkNumber,
      @uploadId,
      @,
      {'content-length': contentLength},
      @putStreamPartCallback.bind(@, @chunkNumber)
    )
    @resume()

  # Start uploading chunks
  initUploadCallback: (error, result) =>
    @log 'initUploadCallback'
    if error
      @log 'startChunking error', error
      # Call original callback with error
      @callback(error, result)
    else
      ###
       result/Outputs something like:
       { bucket: 'bar',
         key: 'foo',
         uploadId: 'VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA' }
      ###
      @uploadId = result.uploadId
      @writable = true
      @doStream()

  # Called from ondrain() when destination stream is free and avaialble
  resume: =>
    # @log 'resume'
    @buffer_empty = true
    @emit('drain')

  # Called when md5 write() returned false and no more data should be written
  pause: ->
    # @log 'pause'
    @buffer_empty = false

  # Called by node/stream.js when connection is dropped
  destroy: ->
    # @log 'destroy'
    @dest.end()
    @cleanup()
    @writable = false
    @readable = false

  # Called when 'data' event is fired on the source stream
  write: (chunk) ->
#    @log 'write to chunk ', @chunkNumber, @writtenChunkSize, '/', @chunkSize, ' | ', @totalWriteSize, '/', @contentLength

    # Start a new chunk
    if @writtenChunkSize+chunk.length>@chunkSize
      # Split chunk into two events
      slicedData = chunk.slice(0, @chunkSize-@writtenChunkSize)
      @emit('data', slicedData)
      chunk = chunk.slice(slicedData.length)

      @totalWriteSize+=slicedData.length
      @writtenChunkSize=0
      @chunkNumber+=1
      @dest.end()

      # Stop this stream from listening
      @cleanup()
      @doStream()

    @emit('data', chunk)
    @totalWriteSize+=chunk.length
    @writtenChunkSize+=chunk.length

    return @buffer_empty

  # Called from source stream when stream ended
  end: (data) ->
    @log 'end ', @chunkNumber, @writtenChunkSize, '/', @chunkSize, ' | ', @totalWriteSize, '/', @contentLength
    @readStreamEnded = true
    @emit('end')

  callbackBadRequest: (document) ->
    @callback(code: 400, document: document)

  putStreamPartCallback: (chunkNumber, error, result) =>
    if error && @writable
      @log 'putStreamPartCallback ERROR chunkNumber', chunkNumber
      # Allow responding with error only once. It's possible that second chunk started, while the first chunk was
      # processing the response
      # Call original callback with error
      if @writable
        @callback(error, result)
        @writable = false
    else
      # It is possible that there is no result, if the connection was dropped
      unless result
        @log "putStreamPartCallback - chunkNumber #{chunkNumber}. No result. Probably connection drop."
        if @writable
          @callbackBadRequest("No response from Amazon. Connection dropped?")
          @writable = false
        return

      @log 'putStreamPartCallback - chunk done', chunkNumber
      @uploadParts[result.partNumber]=result.ETag

      # It is possible that a chunk which is not the last one will return response later than the last chunk
      # This is why we need to check that all chunks are in our dictionary
      if Object.keys(@uploadParts).length == @totalChunkNumber
        @log 'putStreamPartCallback - readStreamEnded'
        # s3.completeUpload(path, uploadId, uploadParts, callback)
        @s3.completeUpload(@path, @uploadId, @uploadParts, @completeUploadCallback)

  completeUploadCallback: (error, result) =>
    @log 'completeUploadCallback'
    @callback(error, result)

  log: (args...) ->
    args.unshift 'ChunkedStream - '
    console.log args...

  ############################################ functions copied from nodejs/stream.js
  ondata: (chunk) =>
    if @dest.writable
      if false == @dest.write(chunk) && @pause
        @pause()

  # Destination drained -> resume here
  ondrain: =>
    if @readable && @resume
      @resume()

  onend: =>
    @log 'onend'
    return if @didOnEnd
    @didOnEnd = true

    @dest.end()

  onclose: =>
    @log 'onclose'
    return if @didOnEnd
    @didOnEnd = true
    @dest.destroy()

  # don't leave dangling pipes when there are errors.
  onerror: (er) =>
    @log 'onerror'
    cleanup()
    if (this.listeners('error').length == 0)
      throw er; # Unhandled stream error in pipe.

  cleanup: =>
    @log 'cleanup'
    @removeListener "data", @ondata
    @dest.removeListener "drain", @ondrain
    @removeListener "end", @onend
    @removeListener "close", @onclose
    @removeListener "error", @onerror
    @dest.removeListener "error", @onerror
    @removeListener "end", @cleanup
    @removeListener "close", @cleanup
    @dest.removeListener "end", @cleanup
    @dest.removeListener "close", @cleanup

  pipe: (@dest, options)->
    #@log 'pipe'
    @on 'data', @ondata
    @dest.on 'drain', @ondrain
    # If the 'end' option is not supplied, dest.end() will be called when
    # @source gets the 'end' or 'close' events.  Only dest.end() once.
    if !@dest._isStdio && (!options || options.end != false)
      @on 'end', @onend
      @on 'close', @onclose

    @on 'end', @cleanup
    @on 'close', @cleanup
    @dest.on "end", @cleanup
    @dest.on "close", @cleanup
    @dest.emit "pipe", @

    # Allow for unix-like usage: A.pipe(B).pipe(C)
    return @dest

module.exports = ChunkedStream