-- 3-way merge resolver for note saves and external-change folding.
-- Pure function: no side effects, no I/O.
--
-- base: what was last loaded/saved by the panel.
-- localBuf: what the user currently has in the editor (possibly dirty).
-- remote: what is on disk right now.
--
-- Returns {status, content} where status is one of:
--   "same"     -> localBuf == remote: nothing to do.
--   "local"    -> remote == base: only local changed -> save localBuf.
--   "remote"   -> localBuf == base: only remote changed -> adopt remote.
--   "merged"   -> both changed but compatibly (appends) -> merged content.
--                 A disk text that is `base .. tail` is also merged as
--                 `localBuf .. tail`, so a launcher quick-capture lands even
--                 when the buffer has unrelated unsaved edits.
--   "conflict" -> both changed incompatibly -> keep localBuf, do not write.

local M = {}

local function isPrefix(s, prefix)
  return s:sub(1, #prefix) == prefix
end

-- Joins two appended tails without gluing the last line of the first one to the
-- first line of the second one.
local function joinTails(left, right)
  if left == "" then
    return right
  end
  if right == "" then
    return left
  end
  if left:sub(-1) == "\n" or right:sub(1, 1) == "\n" then
    return left .. right
  end
  return left .. "\n" .. right
end

function M.resolve(base, localBuf, remote)
  if localBuf == remote then
    return { status = "same", content = remote }
  end
  if remote == base then
    return { status = "local", content = localBuf }
  end
  if localBuf == base then
    return { status = "remote", content = remote }
  end
  -- Both changed: only combinable if both only appended at the end
  -- (base is a prefix of both). An edit in the middle -> conflict.
  -- An empty base is special: the note was empty, so the two texts are two
  -- different things, not two additions. Merging them would invent a text
  -- that nobody wrote.
  if base ~= "" and isPrefix(localBuf, base) and isPrefix(remote, base) then
    local ls = localBuf:sub(#base + 1)
    local rs = remote:sub(#base + 1)
    if ls == rs then
      return { status = "merged", content = localBuf }
    end
    if isPrefix(rs, ls) then
      return { status = "merged", content = base .. rs }
    end
    if isPrefix(ls, rs) then
      return { status = "merged", content = base .. ls }
    end
    -- Distinct appends: keep both, nothing is lost.
    return { status = "merged", content = base .. joinTails(ls, rs) }
  end
  -- The launcher appends to the file while the panel may have unrelated unsaved
  -- edits. A disk text that is exactly base plus a tail is an append, so graft
  -- that tail onto the local buffer instead of calling it a conflict. An empty
  -- base is excluded: there is no way to tell an append from a full text.
  if base ~= "" and isPrefix(remote, base) then
    local tail = remote:sub(#base + 1)
    if localBuf:sub(-#tail) == tail then
      return { status = "merged", content = localBuf }
    end
    return { status = "merged", content = joinTails(localBuf, tail) }
  end
  return { status = "conflict", content = localBuf }
end

return M
