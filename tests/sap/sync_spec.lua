-- Tests for buffer sync logic and is_intentionally_hidden
-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/sap/sync_spec.lua"

describe("sap.buffer sync", function()
    local State = require("sap.state")
    local test_dir

    local function setup_test_dir()
        local tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        vim.fn.mkdir(tmp .. "/child", "p")
        vim.fn.mkdir(tmp .. "/sibling", "p")
        vim.fn.writefile({}, tmp .. "/file.txt")
        vim.fn.writefile({}, tmp .. "/child/nested.txt")
        vim.fn.writefile({}, tmp .. "/.hidden")
        return tmp
    end

    local function cleanup_test_dir(dir)
        vim.fn.delete(dir, "rf")
    end

    before_each(function()
        test_dir = setup_test_dir()
    end)

    after_each(function()
        if test_dir then
            cleanup_test_dir(test_dir)
        end
    end)

    describe("is_intentionally_hidden", function()
        it("should return false for root entry", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)
            assert.is_false(state:is_intentionally_hidden(root))
        end)

        it("should return false for direct children of root", function()
            local state = State.new(test_dir)
            local child = state:get_by_path(test_dir .. "/child")
            assert.is_false(state:is_intentionally_hidden(child))
        end)

        it("should return true for entries outside root", function()
            -- Start in child, then check if parent is "intentionally hidden"
            local state = State.new(test_dir .. "/child")
            -- Add parent to state (simulating what go_to_parent would do)
            state:add_entry(test_dir, nil)

            local parent_entry = state:get_by_path(test_dir)
            assert.is_true(state:is_intentionally_hidden(parent_entry))
        end)

        it("should return true for siblings when root is child dir", function()
            local state = State.new(test_dir)
            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            -- sibling should now be "intentionally hidden" because it's not under child
            local sibling = state:get_by_path(test_dir .. "/sibling")
            if sibling then
                assert.is_true(state:is_intentionally_hidden(sibling))
            end
        end)

        it("should return true for entries under collapsed directory", function()
            local state = State.new(test_dir)
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child) -- Load children
            state:collapse(child) -- Then collapse

            local nested = state:get_by_path(test_dir .. "/child/nested.txt")
            if nested then
                assert.is_true(state:is_intentionally_hidden(nested))
            end
        end)

        it("should return true for hidden files when show_hidden is false", function()
            local state = State.new(test_dir, false) -- show_hidden = false
            local hidden = state:get_by_path(test_dir .. "/.hidden")
            if hidden then
                assert.is_true(state:is_intentionally_hidden(hidden))
            end
        end)

        it("should return false for hidden files when show_hidden is true", function()
            local state = State.new(test_dir, true) -- show_hidden = true
            local hidden = state:get_by_path(test_dir .. "/.hidden")
            assert.is_not_nil(hidden)
            assert.is_false(state:is_intentionally_hidden(hidden))
        end)
    end)

    describe("navigation with sync simulation", function()
        -- Simulates what sync() does
        local function simulate_sync(state, visible_ids)
            state:clear_pending()

            for id, entry in pairs(state.entries) do
                if not visible_ids[id] then
                    if not state:is_intentionally_hidden(entry) then
                        state:mark_delete(entry.path)
                    end
                end
            end
        end

        it("should not mark siblings as deleted after set_root", function()
            local state = State.new(test_dir)

            -- Get all visible IDs initially
            local children = state:get_children(test_dir)
            local root = state:get_by_path(test_dir)

            -- Simulate buffer showing root + children
            local visible_ids = { [root.id] = true }
            for _, c in ipairs(children) do
                if c.id then visible_ids[c.id] = true end
            end

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child)
            state:set_root(child)

            -- After set_root, only child and its children are visible
            local new_visible_ids = { [child.id] = true }
            for _, c in ipairs(state:get_children(state.root_path)) do
                if c.id then new_visible_ids[c.id] = true end
            end

            -- Simulate sync with new visible IDs
            simulate_sync(state, new_visible_ids)

            -- Parent and siblings should NOT be in pending_deletes
            -- because they're "intentionally hidden" (outside root)
            assert.is_false(state:is_deleted(test_dir))
            assert.is_false(state:is_deleted(test_dir .. "/sibling"))
            assert.is_false(state:is_deleted(test_dir .. "/file.txt"))
        end)

        it("should preserve siblings after parent -> child -> parent", function()
            -- Start in child
            local state = State.new(test_dir .. "/child")

            -- Go to parent
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Capture visible entries at parent level
            local root = state:get_by_path(test_dir)
            local visible_ids = { [root.id] = true }
            for _, c in ipairs(state:get_children(test_dir)) do
                if c.id then visible_ids[c.id] = true end
            end

            -- Count children
            local count_at_parent = #state:get_children(test_dir)

            -- Go back to child (set_root)
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            -- Simulate sync - only child and its descendants are visible
            local child_visible_ids = { [child.id] = true }
            for _, c in ipairs(state:get_children(state.root_path)) do
                if c.id then child_visible_ids[c.id] = true end
            end
            simulate_sync(state, child_visible_ids)

            -- Siblings should NOT be deleted (they're outside root)
            assert.is_false(state:is_deleted(test_dir .. "/sibling"))

            -- Go back to parent
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Siblings should still be there
            local count_back_at_parent = #state:get_children(test_dir)
            assert.equals(count_at_parent, count_back_at_parent)
        end)

        it("should actually delete entries that user removed", function()
            local state = State.new(test_dir)

            local root = state:get_by_path(test_dir)
            local children = state:get_children(test_dir)

            -- Simulate buffer showing root + all children except file.txt (user deleted it)
            local visible_ids = { [root.id] = true }
            for _, c in ipairs(children) do
                if c.id and c.name ~= "file.txt" then
                    visible_ids[c.id] = true
                end
            end

            simulate_sync(state, visible_ids)

            -- file.txt SHOULD be deleted (it's visible at root level but not in buffer)
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))
        end)

        it("should preserve deletions when navigating to child", function()
            -- This is the key bug scenario:
            -- 1. Go to parent, delete file
            -- 2. Go to child (set_root)
            -- 3. Go back to parent - deleted file should still be deleted

            local state = State.new(test_dir)

            -- User deletes file.txt
            state:mark_delete(test_dir .. "/file.txt")
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            -- file.txt is now "intentionally hidden" (outside root)
            -- A proper sync should PRESERVE the deletion

            -- Simulate sync with only child entries visible
            local child_visible_ids = { [child.id] = true }
            for _, c in ipairs(state:get_children(state.root_path)) do
                if c.id then child_visible_ids[c.id] = true end
            end

            -- This is the NEW sync behavior: preserve pending edits for hidden entries
            local old_deletes = vim.tbl_extend("force", {}, state.pending_deletes)
            state:clear_pending()

            -- Restore deletes for entries outside root
            for path, _ in pairs(old_deletes) do
                local entry = state:get_by_path(path)
                if entry and state:is_intentionally_hidden(entry) then
                    state.pending_deletes[path] = true
                end
            end

            -- file.txt deletion should be preserved
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))

            -- Navigate back to parent
            state:go_to_parent()

            -- file.txt should still be deleted
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))

            -- And get_children should NOT include it
            local children = state:get_children(test_dir)
            local has_file = false
            for _, c in ipairs(children) do
                if c.name == "file.txt" then has_file = true end
            end
            assert.is_false(has_file, "deleted file should not appear after navigation")
        end)
    end)

    describe("diff.calculate with pending edits", function()
        local diff = require("sap.diff")

        it("should include pending_deletes in diff even when outside root", function()
            local state = State.new(test_dir)

            -- User deletes file.txt at parent level
            state:mark_delete(test_dir .. "/file.txt")

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            -- Now file.txt is "outside root"
            -- But pending_delete should still be preserved

            -- Parse buffer (only child contents)
            local parsed = {}
            parsed[#parsed + 1] = {
                id = child.id,
                path = child.path,
                name = child.name,
                type = "directory",
            }

            -- Calculate diff
            local changes = diff.calculate(state, parsed)

            -- Should include the pending delete for file.txt
            local has_file_delete = false
            for _, d in ipairs(changes.deletes) do
                if d.path == test_dir .. "/file.txt" then
                    has_file_delete = true
                    break
                end
            end
            assert.is_true(has_file_delete, "pending delete should be included in diff")
        end)

        it("should include pending_moves in diff even when outside root", function()
            local state = State.new(test_dir)

            -- User renames file at parent level
            state:mark_move(test_dir .. "/file.txt", test_dir .. "/renamed.txt")

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            local parsed = {}
            parsed[#parsed + 1] = {
                id = child.id,
                path = child.path,
                name = child.name,
                type = "directory",
            }

            local changes = diff.calculate(state, parsed)

            local has_move = false
            for _, m in ipairs(changes.moves) do
                if m.from == test_dir .. "/file.txt" then
                    has_move = true
                    break
                end
            end
            assert.is_true(has_move, "pending move should be included in diff")
        end)

        it("should include pending_creates in diff even when outside root", function()
            local state = State.new(test_dir)

            -- User creates file at parent level
            state:mark_create(test_dir .. "/newfile.txt", "file")

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            local parsed = {}
            parsed[#parsed + 1] = {
                id = child.id,
                path = child.path,
                name = child.name,
                type = "directory",
            }

            local changes = diff.calculate(state, parsed)

            local has_create = false
            for _, c in ipairs(changes.creates) do
                if c.path == test_dir .. "/newfile.txt" then
                    has_create = true
                    break
                end
            end
            assert.is_true(has_create, "pending create should be included in diff")
        end)
    end)
end)
