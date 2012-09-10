config = require('yaml-config')
settings = config.readConfig('config/app.yaml')
fs = require('fs')
http = require('http')
util = require('util')
ecstatic = require('ecstatic')
ec = ecstatic(__dirname)
s3 = require('aws2js').load('s3', settings.aws_key, settings.aws_secret)
rest = require('restler')
ChunkedStream = require('./chunked_stream')

handleS3Response = (req, res, error, result) ->
  # Callback when done uploading
  if error
    for key, value of error.headers
      res.setHeader key, value if key!='content-length'
    # Resume byte range query ... not really an error
    if error.code!=308
      console.log 'S3 error', util.inspect(error.document)
    res.statusCode = error.code
    if error.document?
      res.end util.inspect(error.document)
    else
      res.end()
  else
    console.log 'S3 done', result
    res.end(util.inspect(result))

uploadBinaryStreamToS3 = (filename, req, res) ->
  path = [settings.bucket_name, filename].join '/'
  console.log 'Uploading to', path, 'Content-Length:', req.headers['content-length']

  headers =
    'content-type': 'text/plain',
    'content-length': req.headers['content-length'],
    'content-range': req.headers['content-range']

  # s3.putStream(path, stream, cannedAcl, headers, callback)
  # s3.putStream(path, req, 'public-read', headers, handleS3Response.bind(this, res))
  chunksStream = new ChunkedStream(s3, path, 'public-read', headers, handleS3Response.bind(this, req, res))
  req.pipe(chunksStream)

authenticateUpload = (req, res) ->
  console.log 'Authenticating with', settings.authentication_endpoint
  req = rest.get(settings.authentication_endpoint, {
    headers: { 'Authorization': req.headers['authorization']}
  }).on('complete', (result, response) ->
    if response && response.statusCode in [200, 201]
      return @emit('authorized', result, response)
    return @emit('authorization-error', result, response)
  )

authorized = (req, res, uploadPath, result, response) ->
  console.log 'Starting uploading to', uploadPath
  uploadBinaryStreamToS3(uploadPath, req, res)

authorizationError = (req, res, result, response) ->
  if result instanceof Error
    msg = 'Authorization error: Could not connect to host.'
    console.log 'Result:', result
    res.statusCode = 500
  else
    msg = 'Authorization error: ' + result + ' ' + response.statusCode
    res.statusCode = response.statusCode
  req.resume()
  console.log msg
  res.end msg

server = http.createServer((req, res) ->
  console.log 'Starting request', req.url, '=================================='
  if urlMatches = req.url.match(/^\/upload\/([^\/]+)$/)
    req.pause()
    # Allow only PUT
    return handleS3Response(req, res, code: 400, document: 'Use PUT to upload') unless req.method=='PUT'
    authenticateUpload(req, res).on('authorized', authorized.bind(this, req, res, urlMatches[1]))
      .on('authorization-error', authorizationError.bind(this, req, res))

  else if req.url is '/'
    fs.createReadStream('./index.html').pipe res
  else
    ec req, res
)
server.listen settings.port
console.log 'server listening at port ', settings.port