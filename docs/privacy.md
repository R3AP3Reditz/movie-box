# Privacy and data handling

This describes the checked-in implementation, not a guarantee about independently operated servers, forks, upstream services, or future versions.

## On the device

The Android, Linux, and Windows app stores the selected server address, API token, bookmarks, watch history, and download metadata using `shared_preferences`. Media and subtitle downloads are stored in Android's application documents directory or the desktop application-support directory. On Android each finished video and subtitle is also copied into the device's public Downloads folder under `Download/movie-box/<title>/` for a film or `Download/movie-box/<title>/<SxxExx>/` for an episode, where it is readable by other apps and by file managers; deleting the download in MovieBox removes that copy too. The API token is not stored using a dedicated encrypted credential-storage package.

Device users, backups, debugging tools, or compromised devices may expose local state. Use a unique token for this service rather than reusing an account password or another API credential. Android backup and retention behavior depends on device configuration; no guarantee of secure deletion is made.

## Network requests

- The app sends API requests to the server selected in Settings, including search queries, requested titles, and the configured bearer token when present.
- The checked-in default server is `https://movie-box.n92dev.us.kg`. Set your own address before entering your own server's token. This documentation does not verify that server's availability, retention practices, or operator policies.
- Changing the address in Settings retains the token field, and the connection check sends that token to the new address. Clear the token before switching operators, then enter only credentials intended for the selected server. The current app does not automatically clear or reconfirm credentials when the host changes.
- The API contacts upstream services for catalog and playback information.
- The app requests artwork, video, and subtitles from returned hosts. Those hosts can observe network information such as the client's IP address and the requested resources.
- HTTP deployments do not encrypt requests or tokens in transit. Prefer private networking and HTTPS.

The project does not implement an app account or analytics service of its own. This is not a dependency audit or a claim that upstream services collect no data.

## Server operators

The API uses an in-memory cache for some metadata and has no application database. The Docker startup command disables Uvicorn access logs, but infrastructure, reverse proxies, errors, and upstream services may still produce logs. Operators are responsible for publishing their own retention and access policies and avoiding sensitive request or token logging.

Before posting diagnostic information, remove tokens, personal IP addresses, local filesystem paths where sensitive, watch history, signed playback URLs, and private provider/session data.

## Donations

The optional donation link opens the creator's XibeCode-branded support page at [ai.xibebase.in](https://ai.xibebase.in), rather than a Movie Box checkout. As checked on September 28, 2026, the page says the donor's name, avatar, amount, and review will be publicly listed, while email stays private. It identifies Razorpay as its payment provider. Review the current notice and terms before submitting personal or payment information; these are the site's statements, not an independent privacy audit.

The app's Settings and **Credits and licenses** screens include a Donate button that opens this external site in the device browser only when tapped. Credits also displays the donation address and provides a copy button; a failed browser launch offers the same copy action. Copying writes that public URL to the device clipboard; it does not open the site or send data to it. License and acknowledgment screens read bundled assets and need no server connection.

This repository does not process donations itself. Donations are optional and must not provide exclusive features, access, or advertising in return. The external page's description of XibeCode as open source does not change Movie Box's custom source-available license.

For security concerns, see [SECURITY.md](../SECURITY.md).
