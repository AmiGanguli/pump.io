# user.js
#
# A local user; distinct from a person
#
# Copyright 2011,2012 E14N https://e14n.com/
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
databank = require("databank")
_ = require("underscore")
DatabankObject = databank.DatabankObject
Stamper = require("../stamper").Stamper
bcrypt = require("bcrypt")
Step = require("step")
Person = require("./person").Person
Stream = require("./stream").Stream
Collection = require("./collection").Collection
Activity = require("./activity").Activity
ActivityObject = require("./activityobject").ActivityObject
Favorite = require("./favorite").Favorite
URLMaker = require("../urlmaker").URLMaker
IDMaker = require("../idmaker").IDMaker
Edge = require("./edge").Edge
NoSuchThingError = databank.NoSuchThingError
NICKNAME_RE = /^[a-zA-Z0-9\-_.]{1,64}$/
User = DatabankObject.subClass("user")
exports.User = User

# for updating
User::beforeUpdate = (props, callback) ->
  
  # XXX: required, but immutable. Boooooo.
  unless _(props).has("nickname")
    callback new Error("'nickname' property is required"), null
    return
  else if props.nickname isnt @nickname
    callback new Error("'nickname' is immutable"), null
    return
  else
    delete props.nickname
  
  # XXX: required. Seems not strictly necessary, but whatever.
  unless _(props).has("password")
    callback new Error("'password' property is required"), null
    return
  if User.isBadPassword(props.password)
    callback new User.BadPasswordError(), null
    return
  
  # Callers must omit or leave equal
  if _(props).has("published")
    if props.published isnt @published
      callback new Error("'published' is autogenerated and immutable"), null
      return
    else
      delete props.published
  
  # Callers must omit or leave equal
  if _(props).has("profile")
    
    # XXX: we should probably do some deep-equality check
    if not _(props.profile).has("id") or props.profile.id isnt @profile.id or not _(props.profile).has("objectType") or props.profile.objectType isnt @profile.objectType or not _(props.profile).has("displayName") or props.profile.displayName isnt @profile.displayName
      callback new Error("'profile' is immutable"), null
      return
    else
      delete props.profile
  
  # Callers must omit or leave equal
  if _(props).has("updated") and props.updated isnt @updated
    callback new Error("'updated' is autogenerated"), null
    return
  props.updated = Stamper.stamp()
  Step (->
    bcrypt.genSalt 10, this
    return
  ), ((err, salt) ->
    throw err  if err
    bcrypt.hash props.password, salt, this
    return
  ), (err, hash) ->
    if err
      callback err, null
    else
      props._passwordHash = hash
      delete props.password

      callback null, props
    return

  return

User.BadNicknameError = (nickname) ->
  Error.captureStackTrace this, User.BadNicknameError
  @name = "BadNicknameError"
  @message = "Bad nickname: '" + nickname + "'"
  @nickname = nickname
  return

User.BadNicknameError:: = new Error()
User.BadNicknameError::constructor = User.BadNicknameError
User.BadPasswordError = ->
  Error.captureStackTrace this, User.BadPasswordError
  @name = "BadPasswordError"
  @message = "Bad password"
  return

User.BadPasswordError:: = new Error()
User.BadPasswordError::constructor = User.BadPasswordError

# For creating
User.beforeCreate = (props, callback) ->
  if User.isBadNickname(props.nickname)
    callback new User.BadNicknameError(props.nickname), null
    return
  if User.isBadPassword(props.password)
    callback new User.BadPasswordError(), null
    return
  now = Stamper.stamp()
  props.published = props.updated = now
  Step (->
    bcrypt.genSalt 10, this
    return
  ), ((err, salt) ->
    throw err  if err
    bcrypt.hash props.password, salt, this
    return
  ), (err, hash) ->
    id = undefined
    throw err  if err
    props._passwordHash = hash
    delete props.password

    if err
      callback err, null
    else
      if URLMaker.port is 80 or URLMaker.port is 443
        id = "acct:" + props.nickname + "@" + URLMaker.hostname
      else
        id = URLMaker.makeURL("api/user/" + props.nickname + "/profile")
      props.profile = new Person(
        objectType: "person"
        id: id
      )
      callback null, props
    return

  return

User::afterCreate = (callback) ->
  user = this
  createPerson = (callback) ->
    pprops =
      preferredUsername: user.nickname
      _user: true
      url: URLMaker.makeURL(user.nickname)
      displayName: user.nickname

    pprops._uuid = IDMaker.makeID()
    
    # If we're on the http or https default port, use acct: IDs
    if URLMaker.port is 80 or URLMaker.port is 443
      pprops.id = "acct:" + user.nickname + "@" + URLMaker.hostname
    else
      pprops.id = URLMaker.makeURL("api/user/" + user.nickname + "/profile")
    pprops.links =
      self:
        href: URLMaker.makeURL("api/person/" + pprops._uuid)

      "activity-inbox":
        href: URLMaker.makeURL("api/user/" + user.nickname + "/inbox")

      "activity-outbox":
        href: URLMaker.makeURL("api/user/" + user.nickname + "/feed")

    Person.create pprops, callback
    return

  createStreams = (callback) ->
    Step (->
      i = undefined
      streams = [
        "inbox"
        "outbox"
        "inbox:major"
        "outbox:major"
        "inbox:minor"
        "outbox:minor"
        "inbox:direct"
        "inbox:direct:minor"
        "inbox:direct:major"
        "followers"
        "following"
        "favorites"
        "uploads"
        "lists:person"
      ]
      group = @group()
      i = 0
      while i < streams.length
        Stream.create
          name: "user:" + user.nickname + ":" + streams[i]
        , group()
        i++
      return
    ), callback
    return

  createGalleries = (callback) ->
    Step (->
      Stream.create
        name: "user:" + user.nickname + ":lists:image"
      , this
      return
    ), ((err, str) ->
      i = undefined
      lists = ["Profile Pictures"]
      group = @group()
      throw err  if err
      i = 0
      while i < lists.length
        Collection.create
          author: user.profile
          displayName: lists[i]
          objectTypes: ["image"]
        , group()
        i++
      return
    ), callback
    return

  createVirtualLists = (callback) ->
    Step (->
      i = undefined
      rels =
        followers: "Followers"
        following: "Following"

      group = @group()
      _.each rels, (name, rel) ->
        id = URLMaker.makeURL("/api/user/" + user.nickname + "/" + rel)
        url = URLMaker.makeURL("/" + user.nickname + "/" + rel)
        Collection.create
          author: user.profile
          id: id
          links:
            self:
              href: id

          url: url
          displayName: name
          members:
            url: id
        , group()
        return

      return
    ), callback
    return

  Step (->
    createPerson @parallel()
    createStreams @parallel()
    createGalleries @parallel()
    createVirtualLists @parallel()
    return
  ), (err, person, streams, galleries, virtuals) ->
    if err
      callback err
    else
      user.profile = person
      callback null
    return

  return


# Remove any attributes we don't want to appear in API output.
# By convention, we wipe everything starting with "_".
User::sanitize = ->
  user = this
  _.each user, (value, key) ->
    delete user[key]  if key[0] is "_"
    return

  delete @password

  @profile.sanitize()  if @profile and @profile.sanitize
  return

User::getProfile = (callback) ->
  user = this
  Step (->
    ActivityObject.getObject user.profile.objectType, user.profile.id, this
    return
  ), (err, profile) ->
    if err
      callback err, null
    else
      callback null, profile
    return

  return

User::followersStream = (callback) ->
  user = this
  Stream.get "user:" + user.nickname + ":followers", callback
  return

User::followingStream = (callback) ->
  user = this
  Stream.get "user:" + user.nickname + ":following", callback
  return

User::getFollowers = (start, end, callback) ->
  @getPeople "user:" + @nickname + ":followers", start, end, callback
  return

User::getFollowing = (start, end, callback) ->
  @getPeople "user:" + @nickname + ":following", start, end, callback
  return

User::getPeople = (stream, start, end, callback) ->
  ActivityObject.getObjectStream "person", stream, start, end, callback
  return

User::followerCount = (callback) ->
  Stream.count "user:" + @nickname + ":followers", callback
  return

User::followingCount = (callback) ->
  Stream.count "user:" + @nickname + ":following", callback
  return

User::follow = (other, callback) ->
  user = this
  Step (->
    Edge.create
      from: user.profile
      to: other.profile
    , this
    return
  ), ((err, edge) ->
    group = @group()
    throw err  if err
    user.addFollowing other.profile.id, group()
    other.addFollower user.profile.id, group()
    return
  ), (err) ->
    if err
      callback err
    else
      callback null
    return

  return

User::stopFollowing = (other, callback) ->
  user = this
  Step (->
    Edge.get Edge.id(user.profile.id, other.profile.id), this
    return
  ), ((err, edge) ->
    throw err  if err
    edge.del this
    return
  ), ((err) ->
    group = @group()
    throw err  if err
    user.removeFollowing other.profile.id, group()
    other.removeFollower user.profile.id, group()
    return
  ), (err) ->
    if err
      callback err
    else
      callback null
    return

  return

User::addFollowing = (id, callback) ->
  user = this
  Step (->
    Stream.get "user:" + user.nickname + ":following", this
    return
  ), ((err, stream) ->
    throw err  if err
    stream.deliver id, this
    return
  ), callback
  return

User::addFollower = (id, callback) ->
  user = this
  Step (->
    Stream.get "user:" + user.nickname + ":followers", this
    return
  ), ((err, stream) ->
    throw err  if err
    stream.deliver id, this
    return
  ), callback
  return

User::removeFollowing = (id, callback) ->
  user = this
  Step (->
    Stream.get "user:" + user.nickname + ":following", this
    return
  ), ((err, stream) ->
    throw err  if err
    stream.remove id, this
    return
  ), callback
  return

User::removeFollower = (id, callback) ->
  user = this
  Step (->
    Stream.get "user:" + user.nickname + ":followers", this
    return
  ), ((err, stream) ->
    throw err  if err
    stream.remove id, this
    return
  ), callback
  return

User::addToFavorites = (object, callback) ->
  user = this
  Step (->
    user.favoritesStream this
    return
  ), ((err, stream) ->
    throw err  if err
    stream.deliverObject
      id: object.id
      objectType: object.objectType
    , this
    return
  ), callback
  return

User::removeFromFavorites = (object, callback) ->
  user = this
  Step (->
    user.favoritesStream this
    return
  ), ((err, stream) ->
    throw err  if err
    stream.removeObject
      id: object.id
      objectType: object.objectType
    , this
    return
  ), callback
  return

User::getFavorites = (start, end, callback) ->
  user = this
  Step (->
    user.favoritesStream this
    return
  ), ((err, stream) ->
    throw err  if err
    stream.getObjects start, end, this
    return
  ), ((err, refs) ->
    i = undefined
    parts = undefined
    group = @group()
    throw err  if err
    if refs.length is 0
      callback null, []
    else
      i = 0
      while i < refs.length
        ActivityObject.getObject refs[i].objectType, refs[i].id, group()
        i++
    return
  ), (err, objects) ->
    if err
      callback err, null
    else
      
      # XXX: I *think* these should be in the same order
      # as the refs array.
      callback null, objects
    return

  return

User::favoritesCount = (callback) ->
  user = this
  Step (->
    user.favoritesStream this
    return
  ), ((err, stream) ->
    throw err  if err
    stream.count this
    return
  ), callback
  return

User::favoritesStream = (callback) ->
  Stream.get "user:" + @nickname + ":favorites", (err, stream) ->
    if err and err.name is "NoSuchThingError"
      Stream.create "user:" + @nickname + ":favorites", callback
    else if err
      callback err, null
    else
      callback null, stream
    return

  return

User::uploadsStream = (callback) ->
  user = this
  Stream.get "user:" + user.nickname + ":uploads", callback
  return

User::expand = (callback) ->
  user = this
  ActivityObject.expandProperty user, "profile", callback
  return

User.fromPerson = (id, callback) ->
  Step (->
    User.search
      "profile.id": id
    , this
    return
  ), (err, results) ->
    if err
      callback err, null
    else if results.length is 0
      callback null, null
    else
      callback null, results[0]
    return

  return

User::addToOutbox = (activity, callback) ->
  user = this
  adder = (getter) ->
    (user, activity, callback) ->
      Step (->
        getter user, this
        return
      ), (err, stream) ->
        throw err  if err
        stream.deliver activity.id, callback
        return

      return

  addToMain = adder((user, cb) ->
    user.getOutboxStream cb
    return
  )
  addToMajor = adder((user, cb) ->
    user.getMajorOutboxStream cb
    return
  )
  addToMinor = adder((user, cb) ->
    user.getMinorOutboxStream cb
    return
  )
  Step (->
    addToMain user, activity, @parallel()
    if activity.isMajor()
      addToMajor user, activity, @parallel()
    else
      addToMinor user, activity, @parallel()
    return
  ), callback
  return

User::addToInbox = (activity, callback) ->
  user = this
  adder = (getter) ->
    (user, activity, callback) ->
      Step (->
        getter user, this
        return
      ), ((err, stream) ->
        throw err  if err
        stream.deliver activity.id, this
        return
      ), callback
      return

  isDirectTo = (activity, user) ->
    props = [
      "to"
      "bto"
    ]
    addrs = undefined
    i = undefined
    j = undefined
    i = 0
    while i < props.length
      if _.has(activity, props[i])
        addrs = activity[props[i]]
        j = 0
        while j < addrs.length
          return true  if _.has(addrs[j], "id") and addrs[j].id is user.profile.id
          j++
      i++
    false

  addToMain = adder((user, cb) ->
    user.getInboxStream cb
    return
  )
  addToMajor = adder((user, cb) ->
    user.getMajorInboxStream cb
    return
  )
  addToDirect = adder((user, cb) ->
    user.getDirectInboxStream cb
    return
  )
  addToMinorDirect = adder((user, cb) ->
    user.getMinorDirectInboxStream cb
    return
  )
  addToMajorDirect = adder((user, cb) ->
    user.getMajorDirectInboxStream cb
    return
  )
  addToMinor = adder((user, cb) ->
    user.getMinorInboxStream cb
    return
  )
  Step (->
    direct = isDirectTo(activity, user)
    addToMain user, activity, @parallel()
    addToDirect user, activity, @parallel()  if direct
    if activity.isMajor()
      addToMajor user, activity, @parallel()
      addToMajorDirect user, activity, @parallel()  if direct
    else
      addToMinor user, activity, @parallel()
      addToMinorDirect user, activity, @parallel()  if direct
    return
  ), callback
  return


# Check the credentials for a user
# callback takes args:
# - err: if there's an error (NB: null if credentials don't match)
# - user: User object or null if credentials don't match
User.checkCredentials = (nickname, password, callback) ->
  user = null
  Step (->
    User.get nickname, this
    return
  ), ((err, result) ->
    if err
      if err.name is "NoSuchThingError"
        callback null, null
        return # done
      else
        throw err
    else
      user = result
      bcrypt.compare password, user._passwordHash, this
    return
  ), (err, res) ->
    if err
      callback err, null
    else unless res
      callback null, null
    else
      
      # Don't percolate that hash around
      user.sanitize()
      callback null, user
    return

  return

User::getInboxStream = (callback) ->
  Stream.get "user:" + @nickname + ":inbox", callback
  return

User::getOutboxStream = (callback) ->
  Stream.get "user:" + @nickname + ":outbox", callback
  return

User::getMajorInboxStream = (callback) ->
  Stream.get "user:" + @nickname + ":inbox:major", callback
  return

User::getMajorOutboxStream = (callback) ->
  Stream.get "user:" + @nickname + ":outbox:major", callback
  return

User::getMinorInboxStream = (callback) ->
  Stream.get "user:" + @nickname + ":inbox:minor", callback
  return

User::getMinorOutboxStream = (callback) ->
  Stream.get "user:" + @nickname + ":outbox:minor", callback
  return

User::getLists = (type, callback) ->
  streamName = "user:" + @nickname + ":lists:" + type
  Step (->
    Stream.get streamName, this
    return
  ), ((err, str) ->
    if err and err.name is "NoSuchThingError"
      Stream.create
        name: streamName
      , this
    else if err
      throw err
    else
      this null, str
    return
  ), callback
  return

User::getDirectInboxStream = (callback) ->
  Stream.get "user:" + @nickname + ":inbox:direct", callback
  return

User::getMinorDirectInboxStream = (callback) ->
  Stream.get "user:" + @nickname + ":inbox:direct:minor", callback
  return

User::getMajorDirectInboxStream = (callback) ->
  Stream.get "user:" + @nickname + ":inbox:direct:major", callback
  return


# I keep forgetting these
User::getDirectMinorInboxStream = User::getMinorDirectInboxStream
User::getDirectMajorInboxStream = User::getMajorDirectInboxStream
User.isBadPassword = (password) ->
  badPassword = undefined
  
  # Can't be empty or null
  return true  unless password
  
  # Can't be less than 8
  return true  if password.length < 8
  
  # Can't be all-alpha or all-numeric
  return true  if /^[a-z]+$/.test(password.toLowerCase()) or /^[0-9]+$/.test(password)
  badPassword = require("../badpassword")
  
  # Can't be on list of top 10K passwords
  return true  if _.has(badPassword, password)
  false

User.isBadNickname = (nickname) ->
  nicknameBlacklist = [
    "api"
    "oauth"
  ]
  return true  unless nickname
  return true  unless NICKNAME_RE.test(nickname)
  
  # Since we use /<nickname> as an URL, we can't have top-level URL
  # as user nicknames.
  return true  if nicknameBlacklist.indexOf(nickname) isnt -1
  false

User.schema =
  pkey: "nickname"
  fields: [
    "_passwordHash"
    "email"
    "published"
    "updated"
    "profile"
  ]
  indices: [
    "profile.id"
    "email"
  ]