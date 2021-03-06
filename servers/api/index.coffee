nconf = require("nconf")
request = require("request")
mime = require("mime")
express = require("express")
url = require("url")
querystring = require("querystring")
_ = require("underscore")._
validator = require("json-schema")
mime = require("mime")
gate = require("json-gate")
semver = require("semver")

apiErrors = require("./errors")
apiUrl = nconf.get('url:api')

module.exports = app = express.createServer()


genid = (len = 16, prefix = "", keyspace = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") ->
  prefix += keyspace.charAt(Math.floor(Math.random() * keyspace.length)) while len-- > 0
  prefix


database = require("./lib/database")

Session = database.model("Session")
User = database.model("User")
Plunk = database.model("Plunk")
Package = database.model("Package")



PRUNE_FREQUENCY = 1000 * 60 * 60 * 6 # Prune the sessions every 6 hours
SCORE_INCREMENT = 1000 * 60 * 60 * 6 # Each vote bumps the plunk forward 6 hours

pruneSessions = ->
  console.log "Pruning sessions"
  Session.prune()

setInterval pruneSessions, PRUNE_FREQUENCY
pruneSessions()

app.configure ->
  app.use require("./middleware/cors").middleware()
  app.use require("./middleware/cache").middleware()
  app.use require("./middleware/json").middleware()
  app.use require("./middleware/session").middleware(sessions: database.model("Session"))
    
  app.use app.router
  
  app.use (err, req, res, next) ->
    json = if err.toJSON? then err.toJSON() else
      message: err.message or "Unknown error"
      code: err.code or 500
    
    res.json(json, json.code)
    
    throw err
    
  app.set "jsonp callback", true

###
# RESTful sessions
###


createSession = (token, user, cb) ->
  session = new Session
    last_access: new Date
    keychain: {}
    
  session.user = user if user
  
  session.save (err) -> cb(err, session)

# Convenience endpoint to get the current session or create a new one
app.get "/session", (req, res, next) ->
  res.header "Cache-Control", "no-cache"
  
  if req.session then res.json(req.session)
  else createSession null, null, (err, session) ->
    if err then next(err)
    else res.json(session, 201)


app.post "/sessions", (req, res, next) ->
  createSession null, null, (err, session) ->
    if err then next(err)
    else res.json(session, 201)

app.get "/sessions/:id", (req, res, next) ->
  Session.findById(req.params.id).populate("user").exec (err, session) ->
    if err then next(err)
    else unless session then next(new apiErrors.NotFound)
    else if Date.now() - session.last_access.valueOf() > nconf.get("session:max_age") then next(new apiErrors.NotFound)
    else
      unless session.user then res.json(session.toJSON())
      else User.findById session.user, (err, user) ->
        if err then next(err)
        else res.json(_.extend(session, user: user.toJSON()))



app.del "/sessions/:id/user", (req, res, next) ->
  Session.findById req.params.id, (err, session) ->
    if err then next(err)
    else unless session then next(new apiErrors.NotFound)
    else
      session.user = null
      session.save (err) ->
        if err then next(err)
        else res.json(session)

app.post "/sessions/:id/user", (req, res, next) ->
  Session.findById req.params.id, (err, session) ->
    if err then next(new apiErrors.NotFound)
    else
      unless token = req.param("token") then next(new apiErrors.MissingArgument("token"))
      else
        sessid = req.param("id")
        
        request.get "https://api.github.com/user?access_token=#{token}", (err, response, body) ->
          return next(new apiErrors.Error(err)) if err
          return next(new apiErrors.PermissionDenied) if response.status >= 400
      
          try
            body = JSON.parse(body)
          catch e
            return next(new apiErrors.ParseError)
          
          service_id = "github:#{body.id}"
          
          createUser = (cb) ->
            user_json =
              login: body.login
              gravatar_id: body.gravatar_id
              service_id: service_id
              
            User.create(user_json, cb)
          
          withUser = (err, user) ->
            if err then next(err)
            else
              session.user = user
              session.auth =
                service_name: "github"
                service_token: token
              session.save (err) ->
                if err then next(err)
                else res.json(_.extend(session.toJSON(), user: user.toJSON()), 201)
              
          User.findOne { service_id: service_id }, (err, user) ->
            unless err or not user then withUser(null, user)
            else createUser(withUser)




###
# Plunks
###

ownsPlunk = (session, json) ->
  owner = false
  
  if session
    owner ||= !!(json.user and session.user and json.user.login is session.user.login)
    owner ||= !!(session.keychain and session.keychain.id(json.id)?.token is json.token)

  owner
  
preparePlunk = (session, plunk, populate = {}) ->
  json = _.extend plunk.toJSON(), populate
  
  delete json.token unless ownsPlunk(session, json)
  delete json.voters
  
  if json.files then json.files = do ->
    files = {}
    for file in json.files
      file.raw_url = "#{json.raw_url}#{file.filename}"
      files[file.filename] = file
    files
  
  json.thumbed = session?.user? and plunk.voters.indexOf(""+session.user._id) >= 0
  
  json

preparePlunks = (session, plunks) -> _.map plunks, (plunk) -> preparePlunk(session, plunk)


fetchPlunks = (options, req, res, next) ->
  page = parseInt(req.param("p", "1"), 10)
  limit = parseInt(req.param("pp", "8"))
  
  options.baseUrl ||= "#{apiUrl}/plunks"
  
  search = options.query or {}
  
  if req.user
    search.$or = [
      'private': $ne: true
    ,
      user: req.user._id
    ]
  else
    search.private = $ne: true
  
  query = Plunk.find(search)
  query.sort(options.sort or {updated_at: -1})
  query.select("-files")
  
  query.populate("user").paginate page, limit, (err, plunks, count, pages, current) ->
    if err then next(err)
    else
      link = []
      
      if current < pages
        link.push "<#{options.baseUrl}?p=#{page+1}&pp=#{limit}>; rel=\"next\""
        link.push "<#{options.baseUrl}?p=#{pages}&pp=#{limit}>; rel=\"last\""
      if current > 1
        link.push "<#{options.baseUrl}?p=#{page-1}&pp=#{limit}>; rel=\"prev\""
        link.push "<#{options.baseUrl}?p=1&pp=#{limit}>; rel=\"first\""
        
      res.header("Link", link.join(", ")) if link.length
      res.json(preparePlunks(req.session, plunks))

# List plunks
app.get "/plunks", (req, res, next) ->
  fetchPlunks({}, req, res, next)
  
# List plunks
app.get "/plunks/trending", (req, res, next) ->
  options =
    baseUrl: "#{apiUrl}/plunks/trending"
    sort: "-score -updated_at"
    
  fetchPlunks(options, req, res, next)
  
# List plunks
app.get "/plunks/popular", (req, res, next) ->
  options =
    baseUrl: "#{apiUrl}/plunks/popular"
    sort: "-thumbs -updated_at"
    
  fetchPlunks(options, req, res, next)
  
# Create plunk
app.post "/plunks", (req, res, next) ->
  json = req.body
  schema = require("./schema/plunks/create")
  {valid, errors} = validator.validate(json, schema)
  
  # Despite its awesomeness, revalidator does not support disallow or additionalProperties; we need to check plunk.files size
  if json.files and _.isEmpty(json.files)
    valid = false
    errors.push
      attribute: "minProperties"
      property: "files"
      message: "A minimum of one file is required"
  
  unless valid then next(new apiErrors.ValidationError(errors))
  else
    
    json.files = _.map json.files, (file, filename) ->
      filename: filename
      content: file.content
      mime: mime.lookup(filename, "text/plain")
      
    json.tags = _.uniq(json.tags) if json.tags

    plunk = new Plunk(json)
    plunk.user = req.user._id if req.user
    
    # TODO: This is inefficient as the number space fills up; consider: http://www.faqs.org/patents/app/20090063601
    # Keep generating new ids until not taken
    savePlunk = ->
      plunk._id = if json.private then genid(20) else genid(6)
    
      plunk.save (err) ->
        if err
          if err.code is 11000 then savePlunk()
          else next(err)
        else
          unless req.user and req.session and req.session.keychain
            req.session.keychain.push _id: plunk._id, token: plunk.token
            req.session.save()
          
          populate = {}
          populate.user = req.user.toJSON() if req.user
          
          # User is not populated so we shove it in **UGLY**
          res.json(preparePlunk(req.session, plunk, populate), 201)
          
    savePlunk()

# Read plunk
app.get "/plunks/:id", (req, res, next) ->
  Plunk.findById(req.params.id).populate("user").exec (err, plunk) ->
    if err or not plunk then next(new apiErrors.NotFound)
    else res.json(preparePlunk(req.session, plunk))
    
# Update plunk
app.post "/plunks/:id", (req, res, next) ->
  Plunk.findById(req.params.id).populate("user").exec (err, plunk) ->
    if err or not plunk or not ownsPlunk(req.session, plunk) then next(new apiErrors.NotFound)
    else
      json = req.body
      schema = require("./schema/plunks/update")
      {valid, errors} = validator.validate(json, schema)
      
      # Despite its awesomeness, validator does not support disallow or additionalProperties; we need to check plunk.files size
      if json.files and _.isEmpty(json.files)
        valid = false
        errors.push
          attribute: "minProperties"
          property: "files"
          message: "A minimum of one file is required"
      
      unless valid then next(new apiErrors.ValidationError(errors))
      else
        oldFiles = {}
        
        for file, index in plunk.files
          oldFiles[file.filename] = file
        
        for filename, file of json.files
          # Attempt to delete
          if file is null
            oldFiles[filename].remove() if oldFiles[filename]
          # Modification to an existing file
          else if old = oldFiles[filename]
            if file.filename
              old.filename = file.filename
              old.mime = mime.lookup(file.filename, "text/plain")
            if file.content?
              old.content = file.content
            
            if file.filename or file.content then old.save()
          # New file; handle only if content provided
          else if file.content
            plunk.files.push
              filename: filename
              content: file.content
              
        if json.tags
          plunk.tags ||= []
          
          for tagname, add of json.tags
            if add
              plunk.tags.push(tagname)
            else
              plunk.tags.splice(idx, 1) if (idx = plunk.tags.indexOf(tagname)) >= 0
        
        plunk.tags = _.uniq(plunk.tags)
        plunk.updated_at = new Date
        plunk.description = json.description if json.description
        plunk.user = req.user._id if req.user
        plunk.save (err) ->
          if err then next(new apiErrors.InternalServerError(err))
          else
            populate = {}
            populate.user = req.user.toJSON() if req.user
                
            res.json(preparePlunk(req.session, plunk, populate))
            
# Obtain a list of a plunk's forks
app.get "/plunks/:id/forks", (req, res, next) ->
  Plunk.findOne({_id: req.params.id}).exec (err, plunk) ->
    if err or not plunk then next(new apiErrors.NotFound)
    else
      options =
        query: {fork_of: req.params.id}
        baseUrl: "#{apiUrl}/plunk/#{req.params.id}/forks"
        sort: "-updated_at"
        
      fetchPlunks(options, req, res, next)

# Give a thumbs-up to a plunk
app.post "/plunks/:id/thumb", (req, res, next) ->
  unless req.user then return next(new apiErrors.NotFound)
  
  Plunk.findOne(_id: req.params.id).where("voters").ne(req.user).exec (err, plunk) ->
    if err or not plunk then next(new apiErrors.NotFound)
    else
      plunk.score ||= plunk.created_at.valueOf()
      plunk.thumbs ||= 0
      
      plunk.voters.addToSet(req.user._id)
      plunk.score += SCORE_INCREMENT
      plunk.thumbs++
      
      plunk.save (err) ->
        if err then next(new apiErrors.InternalServerError(err))
        else res.json({ thumbs: plunk.get("thumbs"), score: plunk.score}, 201)

# Remove a thumbs-up to a plunk
app.del "/plunks/:id/thumb", (req, res, next) ->
  unless req.user then return next(new apiErrors.NotFound)
  
  Plunk.findOne(_id: req.params.id).where("voters").equals(req.user).exec (err, plunk) ->
    if err or not plunk then next(new apiErrors.NotFound)
    else
      plunk.voters.remove(req.user)
      plunk.score -= SCORE_INCREMENT
      plunk.thumbs--
      plunk.save (err) ->
        if err then next(new apiErrors.InternalServerError(err))
        else res.json({ thumbs: plunk.get("thumbs"), score: plunk.score}, 200)
        
# Fork an existing plunk
app.post "/plunks/:id/forks", (req, res, next) ->
  Plunk.findById(req.params.id).populate("user").exec (err, parent) ->
    if err or not parent then next(new apiErrors.NotFound)
    else
      json = req.body
      schema = require("./schema/plunks/create")
      {valid, errors} = validator.validate(json, schema)
      
      # Despite its awesomeness, revalidator does not support disallow or additionalProperties; we need to check plunk.files size
      if json.files and _.isEmpty(json.files)
        valid = false
        errors.push
          attribute: "minProperties"
          property: "files"
          message: "A minimum of one file is required"
      
      unless valid then next(new apiErrors.ValidationError(errors))
      else
        
        json.files = _.map json.files, (file, filename) ->
          filename: filename
          content: file.content
          mime: mime.lookup(filename, "text/plain")
      
        json.tags = _.uniq(json.tags) if json.tags
    
        plunk = new Plunk(json)
        plunk.user = req.user._id if req.user
        plunk.fork_of = parent._id
                
        # TODO: This is inefficient as the number space fills up; consider: http://www.faqs.org/patents/app/20090063601
        # Keep generating new ids until not taken
        savePlunk = ->
          plunk._id = if json.private then genid(20) else genid(6)
        
          plunk.save (err) ->
            if err
              if err.code is 11000 then savePlunk()
              else next(err)
            else
              # Update syntax to avoid triggering auto-update of updated_at on parent
              parent.forks.push(plunk._id)
              parent.save()
              
              if not req.user and req.session and req.session.keychain
                req.session.keychain.push _id: plunk._id, token: plunk.token
                req.session.save()
              
              populate = {}
              populate.user = req.user.toJSON() if req.user
                
              res.json(preparePlunk(req.session, plunk, populate), 201)
              
        savePlunk()
    
# Delete plunk
app.del "/plunks/:id", (req, res, next) ->
  Plunk.findById(req.params.id).populate("user").exec (err, plunk) ->
    if err or not plunk or not ownsPlunk(req.session, plunk) then next(new apiErrors.NotFound)
    else plunk.remove ->
      res.send(204)
      
fetchUser = (req, res, next) ->
  User.findOne({login: req.params.username}).exec (err, user) ->
    if err or not user then next(new apiErrors.NotFound)
    else
      req.found_user = user
      next()

# Fetch a user
app.get "/users/:username", fetchUser, (req, res, next) ->
  res.json(req.found_user)

# List a user's plunks
app.get "/users/:username/plunks", fetchUser, (req, res, next) ->
  options =
    query: {user: req.found_user._id}
    baseUrl: "#{apiUrl}/users/#{req.params.username}/plunks"

  fetchPlunks(options, req, res, next)

# List plunks a user gave a thumbs-up
app.get "/users/:username/thumbed", fetchUser, (req, res, next) ->
  options =
    query: {voters: req.found_user._id}
    baseUrl: "#{apiUrl}/users/#{req.params.username}/thumbed"

  fetchPlunks(options, req, res, next)
  
app.get "/tags", (req, res, next) ->
  Plunk.aggregate [
    $unwind: "$tags"
  ,
    $group: _id: "$tags", count: { $sum: 1 }
  ], (err, json) ->
    if err then res.send(404, err)
    else res.json(json)
    
# List plunks having a specific tag
app.get "/tags/:tagname/plunks", (req, res, next) ->
  options =
    query: {tags: req.params.tagname}
    baseUrl: "#{apiUrl}/tags/#{req.params.tagname}/plunks"
    
  fetchPlunks(options, req, res, next)
  


createSchema = gate.createSchema(require("./schema/packages/create.json"))
updateSchema = gate.createSchema(require("./schema/packages/update.json"))


withUser = (req, res, next) ->
  unless req.user then res.send(400)
  else next()

withPackage = (req, res, next) ->
  Package.findOne({name: req.params.name}).select("-_id -versions._id").exec (err, pkg) ->
    if err then res.send(404)
    else
      req.package = pkg
      next()
      

preparePackage = (session, pkg, populate = {}) ->
  json = _.extend pkg.toJSON(), populate
  
  delete json.id
  
  json.editable = true if session?.user and 0 <= json.maintainers.indexOf(session.user.login)
  
  json.versions.sort (v1, v2) -> semver.rcompare(v1.semver, v2.semver)
  
  json

preparePackages = (session, pkgs) -> _.map pkgs, (pkg) -> preparePackage(session, pkg)

app.get "/packages", (req, res, next) ->
  Package.find({}).select("-_id -versions._id").exec (err, docs) ->
    if err then res.send(err, 404)
    else res.json(preparePackages(req.session, docs))
    
    

app.post "/packages", withUser, (req, res, next) ->
  createSchema.validate req.body, (err, json) ->
    if err then res.json err, 400
    else
      json.maintainers = [req.user.login]
      
      versions = []
      versions.push versionDef for version, versionDef of req.body.versions
      
      json.versions = versions
      
      Package.create json, (err, pkg) ->
        if err
          if err.code is 11000 then res.json "A package with that name already exists", 409
          else res.json err.message, 500
        else res.json preparePackage(req.session, pkg), 201

app.get "/packages/:name", withPackage, (req, res, next) ->
  res.json(preparePackage(req.session, req.package))

app.post "/packages/:name", withUser, (req, res, next) ->
  updateSchema.validate req.body, (err, json) ->
    if err
      console.log "Invalid request", arguments...
      res.json err, 400
    else
      for keyword, val of json.keywords
        if val is null then (json.$pullAll ||= keywords: []).keywords.push keyword
        else (json.$pushAll ||= keywords: []).keywords.push keyword
      
      delete json.keywords
      
      
      Package.findOneAndUpdate
        name: req.params.name
        maintainers: req.user.login
      , json, (err, pkg) ->
        if err then res.json(err, 404)
        else res.json(preparePackage(req.session, pkg), 200)

app.del "/packages/:name", withUser, (req, res, next) ->
  Package.findOneAndRemove
    name: req.params.name
    maintainers: req.user.login
  , (err, pkg) ->
    if err then res.json(err, 404)
    else if pkg then res.send(204)
    else res.send(404)


app.all "*", (req, res, next) ->
  next new apiErrors.NotFound