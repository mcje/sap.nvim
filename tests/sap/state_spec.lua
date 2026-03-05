-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
-- Or: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/sap/state_spec.lua"

describe("sap.state", function()
    local State = require("sap.state")
    local test_dir

    -- Helper to create a temp directory structure
    local function setup_test_dir()
        local tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        vim.fn.mkdir(tmp .. "/subdir", "p")
        vim.fn.mkdir(tmp .. "/other", "p")
        vim.fn.writefile({}, tmp .. "/file1.txt")
        vim.fn.writefile({}, tmp .. "/file2.txt")
        vim.fn.writefile({}, tmp .. "/subdir/nested.txt")
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

    describe("new", function()
        it("should create state with root entry", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)
            assert.is_not_nil(root)
            assert.equals(test_dir, root.path)
            assert.equals("directory", root.type)
        end)

        it("should load children of root", function()
            local state = State.new(test_dir)
            local children = state:get_children(test_dir)
            assert.is_true(#children > 0)
        end)

        it("should respect show_hidden option", function()
            local state_hidden = State.new(test_dir, true)
            local state_no_hidden = State.new(test_dir, false)

            local children_hidden = state_hidden:get_children(test_dir)
            local children_no_hidden = state_no_hidden:get_children(test_dir)

            -- Should have more children when showing hidden
            assert.is_true(#children_hidden > #children_no_hidden)
        end)
    end)

    describe("pending edits", function()
        it("should mark entry for deletion", function()
            local state = State.new(test_dir)
            local children = state:get_children(test_dir)
            local file = nil
            for _, c in ipairs(children) do
                if c.type == "file" then
                    file = c
                    break
                end
            end
            assert.is_not_nil(file)

            state:mark_delete(file.path)
            assert.is_true(state:is_deleted(file.path))
            assert.is_true(state:has_pending_edits())
        end)

        it("should exclude deleted entries from get_children", function()
            local state = State.new(test_dir)
            local children_before = state:get_children(test_dir)
            local count_before = #children_before

            local file = nil
            for _, c in ipairs(children_before) do
                if c.type == "file" then
                    file = c
                    break
                end
            end
            assert.is_not_nil(file)

            state:mark_delete(file.path)
            local children_after = state:get_children(test_dir)
            assert.equals(count_before - 1, #children_after)
        end)

        it("should mark entry for move", function()
            local state = State.new(test_dir)
            local old_path = test_dir .. "/file1.txt"
            local new_path = test_dir .. "/renamed.txt"

            state:mark_move(old_path, new_path)
            assert.is_true(state:has_pending_edits())

            -- Entry should appear with new name in get_children
            local children = state:get_children(test_dir)
            local found_new = false
            local found_old = false
            for _, c in ipairs(children) do
                if c.name == "renamed.txt" then found_new = true end
                if c.name == "file1.txt" then found_old = true end
            end
            assert.is_true(found_new)
            assert.is_false(found_old)
        end)

        it("should mark entry for create", function()
            local state = State.new(test_dir)
            local new_path = test_dir .. "/newfile.txt"

            state:mark_create(new_path, "file")
            assert.is_true(state:has_pending_edits())

            -- New entry should appear in get_children
            local children = state:get_children(test_dir)
            local found = false
            for _, c in ipairs(children) do
                if c.name == "newfile.txt" then
                    found = true
                    assert.is_nil(c.id) -- Creates don't have IDs
                    break
                end
            end
            assert.is_true(found)
        end)

        it("should clear pending edits", function()
            local state = State.new(test_dir)
            state:mark_delete(test_dir .. "/file1.txt")
            state:mark_move(test_dir .. "/file2.txt", test_dir .. "/moved.txt")
            state:mark_create(test_dir .. "/new.txt", "file")

            assert.is_true(state:has_pending_edits())
            state:clear_pending()
            assert.is_false(state:has_pending_edits())
        end)
    end)

    describe("expand/collapse", function()
        it("should expand directory", function()
            local state = State.new(test_dir)
            local subdir = state:get_by_path(test_dir .. "/subdir")
            assert.is_not_nil(subdir)
            assert.is_false(state:is_expanded(subdir))

            state:expand(subdir)
            assert.is_true(state:is_expanded(subdir))
        end)

        it("should collapse directory", function()
            local state = State.new(test_dir)
            local subdir = state:get_by_path(test_dir .. "/subdir")
            state:expand(subdir)
            assert.is_true(state:is_expanded(subdir))

            state:collapse(subdir)
            assert.is_false(state:is_expanded(subdir))
        end)

        it("should load children on expand", function()
            local state = State.new(test_dir)
            local subdir = state:get_by_path(test_dir .. "/subdir")
            state:expand(subdir)

            local children = state:get_children(test_dir .. "/subdir")
            assert.is_true(#children > 0)
        end)
    end)

    describe("navigation", function()
        it("should go to parent", function()
            local state = State.new(test_dir .. "/subdir")
            local ok = state:go_to_parent()
            assert.is_true(ok)
            assert.equals(test_dir, state.root_path)
        end)

        it("should set root", function()
            local state = State.new(test_dir)
            local subdir = state:get_by_path(test_dir .. "/subdir")
            state:expand(subdir)

            state:set_root(subdir)
            assert.equals(test_dir .. "/subdir", state.root_path)
        end)

        it("should preserve pending deletes after parent -> child -> parent", function()
            -- This is the failing scenario
            local state = State.new(test_dir .. "/subdir")

            -- Go to parent
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Verify siblings are visible
            local children1 = state:get_children(test_dir)
            local has_other = false
            for _, c in ipairs(children1) do
                if c.name == "other" then has_other = true end
            end
            assert.is_true(has_other, "other dir should be visible after going to parent")

            -- Delete a sibling (simulating user edit)
            state:mark_delete(test_dir .. "/other")

            -- Go back to child (set_root)
            local subdir = state:get_by_path(test_dir .. "/subdir")
            state:set_root(subdir)
            assert.equals(test_dir .. "/subdir", state.root_path)

            -- Now here's the key: pending_delete should be preserved
            -- because "other" is outside the current root (intentionally hidden)
            -- Note: In practice, sync() will clear and recalculate pending edits
            -- So we need to test the full flow with buffer sync

            -- Go back to parent again
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Siblings should still be there in state.entries
            local children2 = state:get_children(test_dir)

            -- If pending_delete was cleared, "other" would reappear
            -- If pending_delete was preserved, "other" would still be deleted
            -- Note: This test doesn't call sync(), so pending_delete IS preserved
            has_other = false
            for _, c in ipairs(children2) do
                if c.name == "other" then has_other = true end
            end
            assert.is_false(has_other, "deleted entry should not reappear")
        end)

        it("should have siblings after parent -> child -> parent (no deletions)", function()
            -- Test that siblings exist after navigation (without any deletions)
            local state = State.new(test_dir .. "/subdir")

            -- Go to parent
            state:go_to_parent()
            local children1 = state:get_children(test_dir)
            local count1 = #children1
            assert.is_true(count1 >= 3, "should have subdir, other, and files")

            -- Go to child
            local subdir = state:get_by_path(test_dir .. "/subdir")
            state:set_root(subdir)

            -- Go back to parent
            state:go_to_parent()
            local children2 = state:get_children(test_dir)
            local count2 = #children2

            assert.equals(count1, count2, "should have same number of children after navigation")
        end)
    end)

    describe("is_expanded edge cases", function()
        it("should handle root being expanded", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)
            assert.is_true(state:is_expanded(root))
        end)
    end)
end)
