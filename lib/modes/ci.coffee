os       = require("os")
git      = require("gift")
Promise  = require("bluebird")
headless = require("./headless")
api      = require("../api")
logger   = require("../logger")
errors   = require("../errors")
upload   = require("../upload")
Project  = require("../project")
terminal = require("../util/terminal")

logException = (err) ->
  ## give us up to 1 second to
  ## create this exception report
  logger.createException(err)
  .timeout(1000)
  .catch ->
    ## dont yell about any errors either

module.exports = {
  getBranchFromGit: (repo) ->
    repo.branchAsync()
    .get("name")
    .catch -> ""

  getMessage: (repo) ->
    repo.current_commitAsync()
    .get("message")
    .catch -> ""

  getAuthor: (repo) ->
    repo.current_commitAsync()
    .get("author")
    .get("name")
    .catch -> ""

  getSha: (repo) ->
    repo.current_commitAsync()
    .get("id")
    .catch -> ""

  getBranch: (repo) ->
    for branch in ["CIRCLE_BRANCH", "TRAVIS_BRANCH", "CI_BRANCH"]
      if b = process.env[branch]
        return Promise.resolve(b)

    @getBranchFromGit(repo)

  ensureProjectAPIToken: (projectId, projectPath, projectName, projectToken) ->
    if not projectToken
      return errors.throw("CI_KEY_MISSING")

    repo = Promise.promisifyAll git(projectPath)

    Promise.props({
      sha:     @getSha(repo)
      branch:  @getBranch(repo)
      author:  @getAuthor(repo)
      message: @getMessage(repo)
    })
    .then (git) ->
      api.createBuild({
        projectId:     projectId
        projectToken:  projectToken
        commitSha:     git.sha
        commitBranch:  git.branch
        commitAuthor:  git.author
        commitMessage: git.message
      })
      .catch (err) ->
        switch err.statusCode
          when 401
            key = key.slice(0, 5) + "..." + key.slice(-5)
            errors.throw("CI_KEY_NOT_VALID", key)
          when 404
            errors.throw("CI_PROJECT_NOT_FOUND")
          else
            ## warn the user that assets will be not recorded
            errors.warning("CI_CANNOT_CREATE_BUILD_OR_INSTANCE", err)

            ## report on this exception
            ## and return null
            logException(err)
            .return(null)

  upload: (options = {}) ->
    {video, screenshots, videoUrl, screenshotsUrl} = options

    uploads = []
    count   = 1

    if videoUrl
      uploads = uploads.concat(upload.video(video, videoUrl, {
        onStart: ->

        onFinish: ->
      }))

    # if screenshotsUrl
    #   uploads = uploads.concat(upload.screenshots(screenshots, screenshotsUrl, {
    #     onStart: (screenshot) ->

    #     onFinish: (screenshot) ->

    #   }))

    Promise.all(uploads)

  uploadAssets: (buildId, stats, screenshots, failingTests) ->
    console.log("")

    terminal.header("Uploading Assets", {
      color: ["bgBlue", "black"]
    })

    console.log("")

    api.createInstance({
      buildId:      buildId
      tests:        stats.tests
      duration:     stats.duration
      passes:       stats.passes
      failures:     stats.failures
      pending:      stats.pending
      video:        !!stats.video
      screenshots:  stats.screenshots.length
    })
    .then (resp) =>
      @upload({
        video:          stats.video
        screenshots:    stats.screenshots
        videoUrl:       resp.videoUploadUrl
        screenshotsUrl: resp.screenshotUploadUrls
      })
      .catch (err) ->
        errors.warning("CI_CANNOT_UPLOAD_ASSETS", err)

        logException(err)
    .catch (err) ->
      errors.warning("CI_CANNOT_CREATE_BUILD_OR_INSTANCE", err)

      logException(err)

  run: (options) ->
    {projectPath} = options

    Project.add(projectPath)
    .then ->
      Project.id(projectPath)
    .then (projectId) =>
      Project.config(projectPath)
      .then (cfg) =>
        {projectName} = cfg

        @ensureProjectAPIToken(projectId, projectPath, projectName, options.key)
        .then (buildId) =>
          ## dont check that the user is logged in
          options.ensureSession = false

          ## collect screenshot metadata
          options.screenshots = []

          headless.run(options)
          .then (stats = {}) =>
            ## if we got a buildId then attempt to
            ## upload these assets
            if buildId
              @uploadAssets(buildId, stats, options.screenshots, options.failingTests)
              .return(stats)
            else
              stats
}