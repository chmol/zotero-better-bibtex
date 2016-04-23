Components.utils.import('resource://gre/modules/Services.jsm')

Zotero.BetterBibTeX.keymanager = new class
  constructor: ->
    @db = Zotero.BetterBibTeX.DB
    @log = Zotero.BetterBibTeX.log
    @resetJournalAbbrevs()

  ###
  three-letter month abbreviations. I assume these are the same ones that the
  docs say are defined in some appendix of the LaTeX book. (I don't have the
  LaTeX book.)
  ###
  months: [ 'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec' ]

  embeddedKeyRE: /\bbibtex: *([^\s\r\n]+)/
  andersJohanssonKeyRE: /\bbiblatexcitekey\[([^\]]+)\]/

  findKeysSQL: "select i.itemID as itemID, i.libraryID as libraryID, idv.value as extra
                from items i
                join itemData id on i.itemID = id.itemID
                join itemDataValues idv on idv.valueID = id.valueID
                join fields f on id.fieldID = f.fieldID
                where f.fieldName = 'extra' and not i.itemID in (select itemID from deletedItems)
                      and (idv.value like '%bibtex:%' or idv.value like '%biblatexcitekey[%' or idv.value like '%biblatexcitekey{%')"

  integer: (v) ->
    return v if typeof v == 'number' || v == null
    _v = parseInt(v)
    throw new Error("#{typeof v} '#{v}' is not an integer-string") if isNaN(_v)
    return _v

  cache: ->
    return (@clone(key) for key in @db.keys.find())

  prime: ->
    sql = "select i.itemID as itemID from items i where itemTypeID not in (1, 14) and not i.itemID in (select itemID from deletedItems)"
    assigned = (key.itemID for key in @db.keys.find())
    sql += " and not i.itemID in #{Zotero.BetterBibTeX.DB.SQLite.Set(assigned)}" if assigned.length > 0

    Zotero.DB.columnQueryAsync(sql).then((items) =>
      if items.length > 100
        return unless Services.prompt.confirm(null, 'Filling citation key cache', """
            You have requested a scan over all citation keys, but have #{items.length} references for which the citation key must still be calculated.
            This might take a long time, and Zotero will freeze while it's calculating them.
            If you click 'Cancel' now, the scan will only occur over the citation keys you happen to have in place.

            Do you wish to proceed calculating all citation keys now?
        """)

      for itemID in items
        @get({itemID}, 'on-export')
      return
    )

  reset: ->
    @resetJournalAbbrevs()
    @db.keys.removeWhere((obj) -> true) # causes cache drop
    @scan()

  resetJournalAbbrevs: ->
    @journalAbbrevs = {
      default: {
        "container-title": { },
        "collection-title": { },
        "institution-entire": { },
        "institution-part": { },
        "nickname": { },
        "number": { },
        "title": { },
        "place": { },
        "hereinafter": { },
        "classic": { },
        "container-phrase": { },
        "title-phrase": { }
      }
    }

  clearDynamic: ->
    @db.keys.removeWhere((obj) -> obj.citekeyFormat)

  journalAbbrev: (item) ->
    return item.journalAbbreviation if item.journalAbbreviation
    return null unless item.itemType in ['journalArticle', 'bill', 'case', 'statute']

    # don't even try to auto-abbrev arxiv IDs
    return null if item.arXiv?.source == 'publicationTitle'

    key = item.publicationTitle || item.reporter || item.code
    return unless key
    return unless Zotero.BetterBibTeX.pref.get('autoAbbrev')

    style = Zotero.BetterBibTeX.pref.get('autoAbbrevStyle') || (style for style in Zotero.Styles.getVisible() when style.usesAbbreviation)[0].styleID

    @journalAbbrevs['default']?['container-title']?[key] || Zotero.Cite.getAbbreviation(style, @journalAbbrevs, 'default', 'container-title', key)
    return @journalAbbrevs['default']?['container-title']?[key] || key

  extract: (item, insitu) ->
    switch
      when item.getField
        throw("#{insitu}: cannot extract in-situ for real items") if insitu
        item = {itemID: item.id, extra: item.getField('extra')}
      when !insitu
        item = {itemID: item.itemID, extra: item.extra.slice(0)}

    return item unless item.extra

    m = @embeddedKeyRE.exec(item.extra) or @andersJohanssonKeyRE.exec(item.extra)
    return item unless m

    item.extra = item.extra.replace(m[0], '').trim()
    item.__citekey__ = m[1].trim()
    delete item.__citekey__ if item.__citekey__ == ''
    return item

  alphabet: (String.fromCharCode('a'.charCodeAt() + n) for n in [0...26])
  postfix: (n) ->
    return '' if n == 0
    n -= 1
    postfix = ''
    while n >= 0
      postfix = @alphabet[n % 26] + postfix
      n = parseInt(n / 26) - 1
    return postfix

  assign: (item, pin) ->
    {citekey, postfix: postfixStyle} = Zotero.BetterBibTeX.formatter.format(item)
    citekey = "zotero-#{if item.libraryID in [undefined, null] then 'null' else item.libraryID}-#{item.itemID}" if citekey in [undefined, null, '']
    return null unless citekey

    libraryID = @integer(if item.libraryID == undefined then Zotero.DB.valueQuery('select libraryID from items where itemID = ?', [item.itemID]) else item.libraryID)
    itemID = @integer(item.itemID)
    in_use = (key.citekey for key in @db.keys.where((o) -> o.libraryID == libraryID && o.itemID != itemID && o.citekey.indexOf(citekey) == 0))
    postfix = { n: 0, c: '' }
    while (citekey + postfix.c) in in_use
      postfix.n++
      if postfixStyle == '0'
        postfix.c = "-#{postfix.n}"
      else
        postfix.c = @postfix(postfix.n)

    res = @set(item, citekey + postfix.c, pin)
    return res

  selected: (action) ->
    throw new Error("Unexpected action #{action}") unless action in ['set', 'reset']

    zoteroPane = Zotero.getActiveZoteroPane()
    items = (item for item in zoteroPane.getSelectedItems() when !item.isAttachment() && !item.isNote())
    items.sort((a, b) -> a.dateAdded.localeCompare(b.dateAdded))

    warn = Zotero.BetterBibTeX.pref.get('warnBulkModify')
    if warn > 0 && items.length > warn
      ids = (parseInt(item.itemID) for item in items)

      if action == 'set'
        affected = items.length
      else
        affected = @db.keys.where((key) -> key.itemID in ids && !key.citekeyFormat).length

      if affected > warn
        params = { treshold: warn, response: null }
        window.openDialog('chrome://zotero-better-bibtex/content/bulk-clear-confirm.xul', '', 'chrome,dialog,centerscreen,modal', params)
        switch params.response
          when 'ok'       then
          when 'whatever' then Zotero.BetterBibTeX.pref.set('warnBulkModify', 0)
          else            return

    for item in items
      @remove(item, action == 'set')

    if action == 'set'
      for item in items
        @assign(item, true)

  save: (item, citekey) ->
    ### only save if no change ###
    item = Zotero.Items.get(item.itemID) unless item.getField

    extra = @extract(item)

    if (extra.__citekey__ == citekey) || (!citekey && !extra.__citekey__)
      return

    extra = extra.extra
    extra += " \nbibtex: #{citekey}" if citekey
    extra = extra.trim()
    item.setField('extra', extra)
    item.save({skipDateModifiedUpdate: true})

  set: (item, citekey, pin) ->
    throw new Error('Cannot set empty cite key') if !citekey || citekey.trim() == ''

    ### no keys for notes and attachments ###
    return unless @eligible(item)

    item = Zotero.Items.get(item.itemID) unless item.getField

    itemID = @integer(item.itemID)
    libraryID = @integer(item.libraryID)

    citekeyFormat = if pin then null else Zotero.BetterBibTeX.citekeyFormat
    key = @db.keys.findOne({itemID})
    return @verify(key) if key && key.citekey == citekey && key.citekeyFormat == citekeyFormat

    if key
      key.citekey = citekey
      key.citekeyFormat = citekeyFormat
      key.libraryID = libraryID
      @db.keys.update(key)
    else
      key = {itemID, libraryID, citekey, citekeyFormat}
      @db.keys.insert(key)

    @save(item, citekey) if pin

    Zotero.BetterBibTeX.auto.markIDs([itemID], 'citekey changed')

    return @verify(key)

  scan: (ids, reason) ->
    if reason in ['delete', 'trash']
      ids = (@integer(id) for id in ids || [])
      @db.keys.removeWhere((o) -> o.itemID in ids)
      return

    switch
      when !ids
        items = Zotero.DB.query(@findKeysSQL)
      when ids.length == 0
        items = []
      when ids.length == 1
        items = Zotero.Items.get(ids[0])
        items = if items then [items] else []
      else
        items = Zotero.Items.get(ids) || []

    pinned = {}
    for item in items
      itemID = @integer(item.itemID)
      citekey = @extract(item).__citekey__
      cached = @db.keys.findOne({itemID})

      continue unless citekey && citekey != ''

      if !cached || cached.citekey != citekey || cached.citekeyFormat != null
        libraryID = @integer(item.libraryID)
        if cached
          cached.citekey = citekey
          cached.citekeyFormat = null
          cached.libraryID = libraryID
          @db.keys.update(cached)
        else
          cached = {itemID, libraryID, citekey: citekey, citekeyFormat: null}
          @db.keys.insert(cached)

      pinned['' + item.itemID] = cached.citekey

    for itemID in ids || []
      continue if pinned['' + itemID]
      @remove({itemID}, true)
      @get({itemID}, 'on-change')

  remove: (item, soft) ->
    @db.keys.removeWhere({itemID: @integer(item.itemID)})
    @save(item) unless soft # only use soft remove if you know a hard set follows!

  eligible: (item) ->
    type = item.itemType
    if !type
      item = Zotero.Items.get(item.itemID) unless item.itemTypeID
      type = switch item.itemTypeID
        when 1 then 'note'
        when 14 then 'attachment'
        else 'reference'
    return false if type in ['note', 'attachment']
    #item = Zotero.Items.get(item.itemID) unless item.getField
    #return false unless item
    #return !item.deleted
    return true

  verify: (entry) ->
    return entry unless Zotero.BetterBibTeX.pref.get('debug') || Zotero.BetterBibTeX.testing

    verify = {citekey: true, citekeyFormat: null, itemID: true, libraryID: null}
    for own key, value of entry
      switch
        when key in ['$loki', 'meta']                                       then  # ignore
        when verify[key] == undefined                                       then  throw new Error("Unexpected field #{key} in #{typeof entry} #{JSON.stringify(entry)}")
        when verify[key] && typeof value == 'number'                        then  delete verify[key]
        when verify[key] && typeof value == 'string' && value.trim() != ''  then  delete verify[key]
        when verify[key] && !value                                          then  throw new Error("field #{key} of #{typeof entry} #{JSON.stringify(entry)} may not be empty")
        else                                                                      delete verify[key]

    verify = Object.keys(verify)
    return entry if verify.length == 0
    throw new Error("missing fields #{verify} in #{typeof entry} #{JSON.stringify(entry)}")

  clone: (key) ->
    return key if key in [undefined, null]
    clone = JSON.parse(JSON.stringify(key))
    delete clone.meta
    delete clone['$loki']

    @verify(clone)
    return clone

  get: (item, pinmode) ->
    if (typeof item.itemID == 'undefined') && (typeof item.key != 'undefined') && (typeof item.libraryID != 'undefined')
      item = Zotero.Items.getByLibraryAndKey(item.libraryID, item.key)

    ### no keys for notes and attachments ###
    return unless @eligible(item)

    ###
    pinmode can be:
    * on-change: generate and pin if pinCitekeys is on-change, 'null' behavior if not
    * on-export: generate and pin if pinCitekeys is on-export, 'null' behavior if not
    * null: fetch -> generate -> return
    ###

    pin = (pinmode == Zotero.BetterBibTeX.pref.get('pinCitekeys'))
    cached = @db.keys.findOne({itemID: @integer(item.itemID)})

    ### store new cache item if we have a miss or if a re-pin is requested ###
    cached = @assign(item, pin) if !cached || (pin && cached.citekeyFormat)
    return @clone(cached)

  resolve: (citekeys, options = {}) ->
    options.libraryID = null if options.libraryID == undefined
    libraryID = @integer(options.libraryID)
    citekeys = [citekeys] unless Array.isArray(citekeys)

    resolved = {}
    for citekey in citekeys
      resolved[citekey] = @db.keys.findObject({citekey, libraryID})
    return resolved

  alternates: (item) ->
    return Zotero.BetterBibTeX.formatter.alternates(item)

