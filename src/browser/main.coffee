global.shellStartTime = Date.now()

process.on 'uncaughtException', (error={}) ->
  console.log(error.message) if error.message?
  console.log(error.stack) if error.stack?

crashReporter = require 'crash-reporter'
app = require 'app'
fs = require 'fs-plus'
path = require 'path'
yargs = require 'yargs'
console.log = require 'nslog'
ipc = require 'ipc'
WebSocket = require('websocket').w3cwebsocket
mkdirp     = require 'mkdirp'
execSync   = require('child_process').execSync
utf8       = require 'utf8'
shell      = require 'shell'

start = ->
  args = parseCommandLine()
  setupAtomHome(args)
  setupCompileCache()
  return if handleStartupEventWithSquirrel()

  # NB: This prevents Win10 from showing dupe items in the taskbar
  app.setAppUserModelId('com.squirrel.atom.atom')

  addPathToOpen = (event, pathToOpen) ->
    event.preventDefault()
    args.pathsToOpen.push(pathToOpen)

  addUrlToOpen = (event, urlToOpen) ->
    event.preventDefault()
    if (urlToOpen.match(/ile\-learn\-open/))
      console.log(urlToOpen)
    else
      args.urlsToOpen.push(urlToOpen)

  app.on 'open-file', addPathToOpen
  app.on 'open-url', addUrlToOpen
  app.on 'will-finish-launching', setupCrashReporter

  app.on 'ready', ->
    app.removeListener 'open-file', addPathToOpen
    app.removeListener 'open-url', addUrlToOpen
    app.registeredTerminals = []
    app.registeredFsConnections = []
    app.sep = if /^win/.test(process.platform) then '\\' else '/'
    app.isWindows = if app.sep == '\\' then true else false
    app.fsConnectionStatus   = 0
    app.termConnectionStatus = 0
    app.moveQueue = []

    fs.makeTreeSync(process.env.ATOM_HOME + '/code')
    app.workingDirPath = path.join(process.env.ATOM_HOME, 'code')

    ipc.on 'connection-state-request', (event) =>
      event.sender.send 'connection-state', connectedStatus()

      for term in app.registeredTerminals
        term.send 'connection-state', connectedStatus()

      for conn in app.registeredFsConnections
        conn.send 'connection-state', connectedStatus()

    ipc.on 'reset-connection', (event) =>
      reconnectWebSocketConnections()

    ipc.on 'register-new-fs-connection', (event, url) =>
      if app.registeredFsConnections.length == 0 && (!app.fsWebSocket || app.fsWebSocket.readyState != app.fsWebSocket.OPEN)
        app.fsSocketUrl = url
        app.registeredFsConnections.push event.sender
        resetFsWebSocketConnection()
      else
        app.registeredFsConnections.push event.sender

      for term in app.registeredTerminals
        term.send 'connection-state', connectedStatus()

      for conn in app.registeredFsConnections
        conn.send 'connection-state', connectedStatus()

    ipc.on 'fs-local-save', (event, payload) ->
      app.fsWebSocket.send payload

    ipc.on 'fs-local-delete', (event, payload) ->
      app.fsWebSocket.send payload

    ipc.on 'register-new-terminal', (event, url) ->
      if app.registeredTerminals.length == 0 && (!app.terminalWebSocket || app.terminalWebSocket.readyState != app.terminalWebSocket.OPEN)
        app.termSocketUrl = url
        app.registeredTerminals.push event.sender
        resetTermWebSocketConnection()
      else
        app.registeredTerminals.push event.sender

        app.registeredTerminals[0].send 'request-terminal-view',
          index: app.registeredTerminals.length - 1

      for term in app.registeredTerminals
        term.send 'connection-state', connectedStatus()

      for conn in app.registeredFsConnections
        conn.send 'connection-state', connectedStatus()

    ipc.on 'terminal-view-response', (event, response) ->
      app.registeredTerminals[response.index].send 'update-terminal-view', response.html

    ipc.on 'terminal-data', (event, data) ->
      app.terminalWebSocket.send data

    ipc.on 'deactivate-listener', (event) ->
      app.registeredTerminals = app.registeredTerminals.filter((el) -> el != event.sender)
      app.registeredFsConnections = app.registeredFsConnections.filter((el) -> el != event.sender)

    AtomApplication = require path.join(args.resourcePath, 'src', 'browser', 'atom-application')
    AtomApplication.open(args)

    console.log("App load time: #{Date.now() - global.shellStartTime}ms") unless args.test

reconnectWebSocketConnections = ->
  app.termConnectionStatus = 0
  app.fsConnectionStatus   = 0

  resetWebSocketCloseHandlers()

  if app.terminalWebSocket.readyState == 1
    app.terminalWebSocket.close()
  else
    resetTermWebSocketConnection()

  if app.fsWebSocket.readyState == 1
    app.fsWebSocket.close()
  else
    resetFsWebSocketConnection()

resetWebSocketCloseHandlers = ->
  app.terminalWebSocket.onclose = (e) =>
    resetTermWebSocketConnection()

  app.fsWebSocket.onclose = (e) =>
    resetFsWebSocketConnection()

resetWebSocketConnections = ->
  resetTermWebSocketConnection()
  resetFsWebSocketConnection()

  for term in app.registeredTerminals
    term.send 'connection-state', connectedStatus()

  for conn in app.registeredFsConnections
    conn.send 'connection-state', connectedStatus()

resetTermWebSocketConnection = ->
  app.termConnectionStatus = 0
  app.terminalWebSocket = new WebSocket(app.termSocketUrl)

  app.terminalWebSocket.onmessage = (e) =>
    for term in app.registeredTerminals
      try
        term.send 'terminal-message', e.data
      catch
        console.log 'Error sending data to term: ' + term

  app.terminalWebSocket.onopen = (e) =>
    app.termConnectionStatus = 1

    for term in app.registeredTerminals
      try
        term.send 'connection-state', connectedStatus()
      catch
        console.log 'Error sending connection-state to term: ' + term

  app.terminalWebSocket.onclose = =>
    app.termConnectionStatus = 0

    for term in app.registeredTerminals
      try
        term.send 'connection-state', connectedStatus()
      catch
        console.log 'Error sending connection-state to term: ' + term

resetFsWebSocketConnection = ->
  app.fsConnectionStatus = 0
  app.fsWebSocket = new WebSocket(app.fsSocketUrl)

  app.fsWebSocket.onopen = (e) =>
    app.fsConnectionStatus = 1

    for registeredConn in app.registeredFsConnections
      try
        registeredConn.send 'connection-state', connectedStatus()
      catch
        console.log 'Error sending connection-state to conn: ' + registeredConn

  app.fsWebSocket.onclose = (e) =>
    app.fsConnectionStatus = 0

    for registeredConn in app.registeredFsConnections
      try
        registeredConn.send 'connection-state', connectedStatus()
      catch
        console.log 'Error sending connection-state to conn: ' + registeredConn

  app.fsWebSocket.onmessage = (e) =>
    try
      event = JSON.parse(e.data)

      if !(event.location.match(/node_modules/) || event.file.match(/node_modules/))
        switch event.event
          when 'remote_create'
            if event.directory
              if app.isWindows
                execSync('mkdir ' + app.workingDirPath + app.sep + formatFilePath(event.location) + app.sep + event.file)
              else
                fs.makeTreeSync(app.workingDirPath + app.sep + event.location + app.sep + event.file)
            else
              fs.makeTreeSync(app.workingDirPath + app.sep + event.location)

              fs.openSync(app.workingDirPath + app.sep + formatFilePath(event.location) + app.sep + event.file, 'a')

              app.fsWebSocket.send JSON.stringify({
                action: 'request_content',
                location: event.location,
                file: event.file
              })
          when 'content_response'
            content = new Buffer(event.content, 'base64').toString()

            try
              writableContent = utf8.decode(content)
            catch
              writableContent = content

            fs.writeFileSync app.workingDirPath + app.sep + formatFilePath(event.location) + app.sep + event.file, writableContent
          when 'remote_delete'
            shell.moveItemToTrash(app.workingDirPath + app.sep + formatFilePath(event.location) + app.sep + event.file)
          when 'remote_moved_from'
            app.moveQueue.push(event)
          when 'remote_moved_to'
            # TODO: Dry this the heck up
            movedFrom = app.moveQueue.shift()
            movedTo   = event
            shell.moveItemToTrash(app.workingDirPath + app.sep + movedFrom.location + app.sep + movedFrom.file)

            if movedTo.directory
              if app.isWindows
                execSync('mkdir ' + app.workingDirPath + app.sep + formatFilePath(movedTo.location) + app.sep + movedTo.file)
              else
                fs.makeTreeSync(app.workingDirPath + app.sep + movedTo.location + app.sep + movedTo.file)
            else
              fs.makeTreeSync(app.workingDirPath + app.sep + movedTo.location)

              fs.openSync(app.workingDirPath + app.sep + formatFilePath(movedTo.location) + app.sep + movedTo.file, 'a')

              app.fsWebSocket.send JSON.stringify({
                action: 'request_content',
                location: movedTo.location,
                file: movedTo.file
              })
          when 'remote_modify'
            if !event.directory
              if app.isWindows
                execSync('mkdir ' + app.workingDirPath + app.sep + formatFilePath(event.location))
              else
                mkdirp.sync(app.workingDirPath + app.sep + event.location)

              fs.openSync(app.workingDirPath + app.sep + formatFilePath(event.location) + app.sep + event.file, 'a')

              app.fsWebSocket.send JSON.stringify({
                action: 'request_content',
                location: event.location,
                file: event.file
              })
          when 'remote_open'
            for conn in app.registeredFsConnections
              try
                if event.location.length
                  conn.send 'remote-open-event', formatFilePath(event.location) + app.sep + event.file
                else
                  conn.send 'remote-open-event', event.file
              catch
                console.log 'Error sending remote open message to conn: ' + conn

    catch err
      remoteErr(err)

    remoteLog('SyncedFS debug: ' + e)

connected = ->
  return app.fsConnectionStatus + app.termConnectionStatus == 2

connectedStatus = ->
  return if connected() then 'open' else 'closed'

remoteLog = (message) ->
  for conn in app.registeredFsConnections
    try
      conn.send 'remote-log', message
    catch
      console.log 'Error sending remote logging to conn: ' + conn

remoteErr = (err, message) ->
  for conn in app.registeredFsConnections
    if message
      remoteLog(message + ' ' + err.message)
    else
      remoteLog(err.message)

    remoteLog('Error in: ' + err.fileName + ':' + err.lineNumber)

formatFilePath = (path) ->
  if path.match(/:\\/)
    return path.replace(/(.*:\\)/, '/').replace(/\\/g, '/')
  else
    return path

normalizeDriveLetterName = (filePath) ->
  if process.platform is 'win32'
    filePath.replace /^([a-z]):/, ([driveLetter]) -> driveLetter.toUpperCase() + ":"
  else
    filePath

handleStartupEventWithSquirrel = ->
  return false unless process.platform is 'win32'
  SquirrelUpdate = require './squirrel-update'
  squirrelCommand = process.argv[1]
  SquirrelUpdate.handleStartupEvent(app, squirrelCommand)

setupCrashReporter = ->
  crashReporter.start(productName: 'Atom', companyName: 'GitHub')

setupAtomHome = ({setPortable}) ->
  return if process.env.ATOM_HOME

  atomHome = path.join(app.getHomeDir(), '.atom')
  AtomPortable = require './atom-portable'

  if setPortable and not AtomPortable.isPortableInstall(process.platform, process.env.ATOM_HOME, atomHome)
    try
      AtomPortable.setPortable(atomHome)
    catch error
      console.log("Failed copying portable directory '#{atomHome}' to '#{AtomPortable.getPortableAtomHomePath()}'")
      console.log("#{error.message} #{error.stack}")

  if AtomPortable.isPortableInstall(process.platform, process.env.ATOM_HOME, atomHome)
    atomHome = AtomPortable.getPortableAtomHomePath()

  try
    atomHome = fs.realpathSync(atomHome)

  process.env.ATOM_HOME = atomHome

setupCompileCache = ->
  compileCache = require('../compile-cache')
  compileCache.setAtomHomeDirectory(process.env.ATOM_HOME)

parseCommandLine = ->
  version = app.getVersion()
  options = yargs(process.argv[1..]).wrap(100)
  options.usage """
    Atom Editor v#{version}

    Usage: atom [options] [path ...]

    One or more paths to files or folders may be specified. If there is an
    existing Atom window that contains all of the given folders, the paths
    will be opened in that window. Otherwise, they will be opened in a new
    window.

    Environment Variables:

      ATOM_DEV_RESOURCE_PATH  The path from which Atom loads source code in dev mode.
                              Defaults to `~/github/atom`.

      ATOM_HOME               The root path for all configuration files and folders.
                              Defaults to `~/.atom`.
  """
  # Deprecated 1.0 API preview flag
  options.alias('1', 'one').boolean('1').describe('1', 'This option is no longer supported.')
  options.boolean('include-deprecated-apis').describe('include-deprecated-apis', 'This option is not currently supported.')
  options.alias('d', 'dev').boolean('d').describe('d', 'Run in development mode.')
  options.alias('f', 'foreground').boolean('f').describe('f', 'Keep the browser process in the foreground.')
  options.alias('h', 'help').boolean('h').describe('h', 'Print this usage message.')
  options.alias('l', 'log-file').string('l').describe('l', 'Log all output to file.')
  options.alias('n', 'new-window').boolean('n').describe('n', 'Open a new window.')
  options.boolean('profile-startup').describe('profile-startup', 'Create a profile of the startup execution time.')
  options.alias('r', 'resource-path').string('r').describe('r', 'Set the path to the Atom source directory and enable dev-mode.')
  options.boolean('safe').describe('safe', 'Do not load packages from ~/.atom/packages or ~/.atom/dev/packages.')
  options.boolean('portable').describe('portable', 'Set portable mode. Copies the ~/.atom folder to be a sibling of the installed Atom location if a .atom folder is not already there.')
  options.alias('t', 'test').boolean('t').describe('t', 'Run the specified specs and exit with error code on failures.')
  options.string('timeout').describe('timeout', 'When in test mode, waits until the specified time (in minutes) and kills the process (exit code: 130).')
  options.alias('v', 'version').boolean('v').describe('v', 'Print the version.')
  options.alias('w', 'wait').boolean('w').describe('w', 'Wait for window to be closed before returning.')
  options.string('socket-path')

  args = options.argv

  if args.help
    process.stdout.write(options.help())
    process.exit(0)

  if args.version
    process.stdout.write("#{version}\n")
    process.exit(0)

  executedFrom = args['executed-from']?.toString() ? process.cwd()
  devMode = args['dev']
  safeMode = args['safe']
  pathsToOpen = args._
  test = args['test']
  timeout = args['timeout']
  newWindow = args['new-window']
  pidToKillWhenClosed = args['pid'] if args['wait']
  logFile = args['log-file']
  socketPath = args['socket-path']
  profileStartup = args['profile-startup']
  urlsToOpen = []
  devResourcePath = process.env.ATOM_DEV_RESOURCE_PATH ? path.join(app.getHomeDir(), 'github', 'atom')
  setPortable = args.portable

  if args['resource-path']
    devMode = true
    resourcePath = args['resource-path']

  devMode = true if test
  resourcePath ?= devResourcePath if devMode

  unless fs.statSyncNoException(resourcePath)
    resourcePath = path.dirname(path.dirname(__dirname))

  # On Yosemite the $PATH is not inherited by the "open" command, so we have to
  # explicitly pass it by command line, see http://git.io/YC8_Ew.
  process.env.PATH = args['path-environment'] if args['path-environment']

  resourcePath = normalizeDriveLetterName(resourcePath)
  devResourcePath = normalizeDriveLetterName(devResourcePath)

  {resourcePath, devResourcePath, pathsToOpen, urlsToOpen, executedFrom, test,
   version, pidToKillWhenClosed, devMode, safeMode, newWindow,
   logFile, socketPath, profileStartup, timeout, setPortable}

start()
