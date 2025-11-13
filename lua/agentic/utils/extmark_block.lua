local GLYPHS = {
    TOP_LEFT = "╭",
    BOTTOM_LEFT = "╰",
    HORIZONTAL = "─",
    VERTICAL = "│",
}

local NAMESPACE_ID = vim.api.nvim_create_namespace("agentic_extmark_block")

---@class agentic.utils.ExtmarkBlock
local ExtmarkBlock = {}

---@class agentic.utils.ExtmarkBlock.RenderBlockOpts
---@field header_line integer 0-indexed line number for header
---@field body_start? integer 0-indexed start line for body (optional)
---@field body_end? integer 0-indexed end line for body (optional)
---@field footer_line? integer 0-indexed line number for footer (optional)
---@field hl_group string Highlight group name

---Renders a complete block with header, optional body, and optional footer
---@param bufnr integer
---@param opts agentic.utils.ExtmarkBlock.RenderBlockOpts
---@return nil
function ExtmarkBlock.render_block(bufnr, opts)
    -- Add header glyph
    vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE_ID, opts.header_line, 0, {
        virt_text = {
            { GLYPHS.TOP_LEFT .. GLYPHS.HORIZONTAL .. " ", opts.hl_group },
        },
        virt_text_pos = "inline",
        hl_mode = "combine",
    })

    -- Add body pipe padding if body exists
    if opts.body_start and opts.body_end then
        for line_num = opts.body_start, opts.body_end do
            vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE_ID, line_num, 0, {
                virt_text = { { GLYPHS.VERTICAL .. " ", opts.hl_group } },
                virt_text_pos = "inline",
                hl_mode = "combine",
            })
        end
    end

    -- Add footer glyph if footer exists
    if opts.footer_line then
        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE_ID, opts.footer_line, 0, {
            virt_text = {
                { GLYPHS.BOTTOM_LEFT .. GLYPHS.HORIZONTAL .. " ", opts.hl_group },
            },
            virt_text_pos = "inline",
            hl_mode = "combine",
        })
    end
end

return ExtmarkBlock
