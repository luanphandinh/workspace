# 1. Overview & Background

- `author.address`:
  - Let the author hide it in feed responses.
  - Post text is unchanged.
- Target: one account setting applies to old and new feed items.
- Fictional example:
  - HTTP server and Go `FeedService` in one `example-api` binary, backed by PostgreSQL.
  - Paths below are illustrative.

# 2. Links

- [Example requirement](https://example.com/specs/feed-privacy)

# 3. Solution Overview

![Set account privacy, then apply it when building feed responses](assets/hide-address.svg)

# 4. Design Decisions

- N/A.

# 5. External Technical Design

| API | Change |
| --- | --- |
| `PATCH /v1/me/feed-privacy` | New. Body `{"hide_address":true}`; `204` after persistence. |
| `GET /v1/feed` | Existing. `author.address` becomes optional; hidden means omitted, not an empty string. |

- `PATCH /v1/me/feed-privacy`:
  - Return `400` unless `hide_address` is a boolean.
  - Use the authenticated user ID, not a caller-selected account.
  - Repeating the same patch is safe.

# 6. Internal Technical Design

## 6.1 Service: `example-api`

### Logic change

- `FeedService.SetPrivacy`:
  - Update only the authenticated user's setting.
  - Default `false` preserves existing behavior.
- `FeedService.List`:
  - Join current author settings.
  - Call `toAuthor` to build the author response.
  - Never serialize an address from a stored feed snapshot or cached response.
  - Fail the request if author settings cannot be read.
  - Do not cache the personalized response.
  - Hiding an address does not erase data already downloaded by a client.

### Code changes

<details>
<summary><strong>Code change — hide_address (migrations/002_feed_privacy.sql)</strong></summary>

```sql
ALTER TABLE users
    ADD COLUMN hide_address boolean NOT NULL DEFAULT false;
```

</details>

<details>
<summary><strong>Code change — toAuthor (internal/feed/response.go)</strong></summary>

```go
type AuthorRow struct {
    ID          string
    Address     string
    HideAddress bool
}

type Author struct {
    ID      string  `json:"id"`
    Address *string `json:"address,omitempty"`
}

func toAuthor(row AuthorRow) Author {
    author := Author{ID: row.ID}
    if !row.HideAddress {
        author.Address = &row.Address
    }
    return author
}
```

- Wire `PATCH /v1/me/feed-privacy` to `FeedService.SetPrivacy`.
- Select `users.hide_address` in the existing feed query.
- Verify JSON field absence, not just an empty address.

</details>

# 7. Rollout Plan

1. Add the column and deploy readers that understand missing addresses.
2. Deploy all server instances with the read filter, then expose the setting.

- After users opt in, do not roll back to an address-disclosing reader.

# 8. Release Checklist

- [ ] Apply the migration and deploy the server.
- [ ] Enable the setting after all readers enforce it.
- [ ] Verify old and new feed items omit hidden addresses.
