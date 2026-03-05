-- Integration tests for navigation actions
-- These tests simulate the full flow including buffer manipulation

describe("sap.actions integration", function()
    local State = require("sap.state")
    local buffer = require("sap.buffer")
    local parser = require("sap.parser")
    local test_dir

    local function setup_test_dir()
        local tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        vim.fn.mkdir(tmp .. "/child", "p")
        vim.fn.mkdir(tmp .. "/sibling", "p")
        vim.fn.writefile({}, tmp .. "/file.txt")
        vim.fn.writefile({}, tmp .. "/child/nested.txt")
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
        -- Clean up any test buffers
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if buffer.states[bufnr] then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end
    end)

    describe("parent -> child -> parent navigation", function()
        it("should preserve all entries after full navigation cycle", function()
            -- Create buffer starting in child directory
            local bufnr = buffer.create(test_dir .. "/child")
            assert.is_not_nil(bufnr)

            local state = buffer.states[bufnr]
            assert.is_not_nil(state)
            assert.equals(test_dir .. "/child", state.root_path)

            -- Simulate "go to parent" action
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Get children at parent level
            local children1 = state:get_children(test_dir)
            local names1 = {}
            for _, c in ipairs(children1) do
                names1[c.name] = true
            end

            assert.is_true(names1["child"], "child should be visible")
            assert.is_true(names1["sibling"], "sibling should be visible")
            assert.is_true(names1["file.txt"], "file.txt should be visible")

            -- Simulate "set root" to go back to child
            local child_entry = state:get_by_path(test_dir .. "/child")
            state:set_root(child_entry)
            assert.equals(test_dir .. "/child", state.root_path)

            -- Simulate sync() after set_root - siblings should be "intentionally hidden"
            -- (This is what buffer.sync does, but we're testing the state logic)
            state:clear_pending()
            -- At this point, sibling and file.txt are outside root, so not deleted

            -- Go back to parent
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Get children again
            local children2 = state:get_children(test_dir)
            local names2 = {}
            for _, c in ipairs(children2) do
                names2[c.name] = true
            end

            -- All entries should still be there
            assert.is_true(names2["child"], "child should still be visible")
            assert.is_true(names2["sibling"], "sibling should still be visible after navigation")
            assert.is_true(names2["file.txt"], "file.txt should still be visible after navigation")

            -- Count should be the same
            assert.equals(#children1, #children2, "should have same number of children")
        end)

        it("should preserve user deletions after navigation", function()
            local bufnr = buffer.create(test_dir .. "/child")
            local state = buffer.states[bufnr]

            -- Go to parent
            state:go_to_parent()

            -- User deletes file.txt
            state:mark_delete(test_dir .. "/file.txt")
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))

            -- Verify file is excluded from get_children
            local children1 = state:get_children(test_dir)
            local has_file = false
            for _, c in ipairs(children1) do
                if c.name == "file.txt" then has_file = true end
            end
            assert.is_false(has_file, "deleted file should not appear")

            -- Go to child
            local child_entry = state:get_by_path(test_dir .. "/child")
            state:set_root(child_entry)

            -- File.txt is now outside root, so it's "intentionally hidden"
            -- We DON'T want to clear pending_delete for it in a real sync

            -- Go back to parent
            state:go_to_parent()

            -- The deletion should NOT be preserved in state because sync clears pending
            -- But the file entry itself is still in state.entries
            -- This is where the bug was - sync was incorrectly clearing the deletion

            -- In the REAL implementation, sync() recalculates pending from buffer
            -- If file.txt was deleted from buffer, sync() would re-mark it as deleted
            -- The key is that sync() shouldn't mark siblings as deleted when they're outside root

            local children2 = state:get_children(test_dir)
            -- Note: without calling sync(), pending_delete is still set from earlier
            has_file = false
            for _, c in ipairs(children2) do
                if c.name == "file.txt" then has_file = true end
            end
            assert.is_false(has_file, "file should still be deleted")
        end)
    end)

    describe("buffer sync behavior", function()
        it("should detect deletions from buffer", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            -- Get initial line count
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local initial_count = #lines

            -- Delete a line from buffer (simulating user action)
            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})

            -- Call sync
            buffer.sync(bufnr)

            -- Should have marked something as deleted
            assert.is_true(state:has_pending_edits())
        end)
    end)
end)
