local M = {}

M.defaults = {
  filetypes = { 'markdown', 'text', 'tex', 'plaintex', 'norg' },
  date_format = '%y/%m/%d',
  done_retention_days = 10,
  todo_json_name = 'todo.json',
  statuses = {
    todo = 'TODO',
    blocked = 'BLOCKED',
    doing = 'DOING',
    peer_review = 'PEER_REVIEW',
    done = 'DONE',
  },
  priorities = {
    low = 'LOW',
    medium = 'MEDIUM',
    high = 'HIGH',
  },
  picker_badges = {
    low = '  ',
    medium = '🟡',
    high = '🔴',
  },
  ui = {
    picker = {
      title = 'TODOs · / search · Enter log · S status · P priority · p parent · o order · x done-cycle · f filter · t task · a subtask · e source · m reference',
      row_gap = ' ',
      progress_sep = '  ',
      message_indent = 5,
      layout = {
        cycle = true,
        preview = false,
        hidden = { 'preview' },
        auto_hide = { 'input' },
        layout = {
          backdrop = false,
          width = 0.58,
          min_width = 88,
          max_width = 120,
          height = 0.72,
          min_height = 14,
          box = 'vertical',
          border = 'rounded',
          title = '{title} {live} {flags}',
          title_pos = 'center',
          { win = 'input', height = 1, border = 'bottom' },
          { win = 'list', border = 'none' },
          { win = 'preview', title = '{preview}', height = 0.45, border = 'top' },
        },
      },
      tree = {
        base = '  ',
        indent_step = '  ',
        open = '▾ ',
        closed = '▸ ',
        leaf = '↳ ',
      },
    },
    panel = {
      title = 'Task Details',
      border = 'rounded',
      indent = '  ',
      details_indent = '  ',
      section_sep_char = '─',
      meta_label_width = 10,
      inner_width_min = 40,
      inner_width_max = 56,
      inner_width_ratio = 0.62,
      float_width_ratio = 0.82,
      float_height_ratio = 0.76,
      min_height = 14,
      breakindentopt = 'shift:2,min:18',
    },
  }
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.options, opts or {})
  M.update_helpers()
end

function M.update_helpers()
  local Config = M.options
  M.STATUS_TODO = Config.statuses.todo
  M.STATUS_BLOCKED = Config.statuses.blocked
  M.STATUS_DOING = Config.statuses.doing
  M.STATUS_PEER_REVIEW = Config.statuses.peer_review
  M.STATUS_DONE = Config.statuses.done

  M.PRIORITY_LOW = Config.priorities.low
  M.PRIORITY_MEDIUM = Config.priorities.medium
  M.PRIORITY_HIGH = Config.priorities.high

  M.STATUS_SORT = {
    [M.STATUS_TODO] = 0,
    [M.STATUS_BLOCKED] = 1,
    [M.STATUS_DOING] = 2,
    [M.STATUS_PEER_REVIEW] = 3,
    [M.STATUS_DONE] = 4,
  }

  M.PRIORITY_SORT = {
    [M.PRIORITY_HIGH] = 1,
    [M.PRIORITY_MEDIUM] = 2,
    [M.PRIORITY_LOW] = 3,
  }

  M.STATUS_NEXT = {
    [M.STATUS_TODO] = M.STATUS_BLOCKED,
    [M.STATUS_BLOCKED] = M.STATUS_DOING,
    [M.STATUS_DOING] = M.STATUS_PEER_REVIEW,
    [M.STATUS_PEER_REVIEW] = M.STATUS_DONE,
    [M.STATUS_DONE] = M.STATUS_TODO,
  }
  M.PRIORITY_NEXT = {
    [M.PRIORITY_LOW] = M.PRIORITY_MEDIUM,
    [M.PRIORITY_MEDIUM] = M.PRIORITY_HIGH,
    [M.PRIORITY_HIGH] = M.PRIORITY_LOW,
  }
  M.STATUS_COLOR = {
    [0] = 'TodoStatusInfo',
    [1] = 'TodoStatusBlocked',
    [2] = 'TodoStatusWarn',
    [3] = 'TodoStatusPeerReview',
    [4] = 'TodoStatusDone',
  }
  M.STATUS_LABEL = {
    [M.STATUS_TODO] = 'Todo',
    [M.STATUS_BLOCKED] = 'Blocked',
    [M.STATUS_DOING] = 'Doing',
    [M.STATUS_PEER_REVIEW] = 'Peer Review',
    [M.STATUS_DONE] = 'Done',
  }
  M.PRIORITY_BADGE = {
    [M.PRIORITY_HIGH] = Config.picker_badges.high,
    [M.PRIORITY_MEDIUM] = Config.picker_badges.medium,
    [M.PRIORITY_LOW] = Config.picker_badges.low,
  }
  M.PRIORITY_HL = {
    [M.PRIORITY_HIGH] = 'DiagnosticError',
    [M.PRIORITY_MEDIUM] = 'DiagnosticWarn',
    [M.PRIORITY_LOW] = 'NonText',
  }
  M.PARENT_HINT_HL = 'TodoParentHint'
  M.TAG_HEADER_HL = 'TodoTagHeader'
  M.TITLE_HL_BLOCKED = 'TodoTitleBlocked'
  M.TITLE_HL_PEER_REVIEW = 'TodoTitlePeerReview'

  M.STATUS_SOURCE_HL = {
    [0] = 'DiagnosticInfo',
    [1] = 'DiagnosticError',
    [2] = 'DiagnosticWarn',
    [3] = 'Directory',
    [4] = 'Comment',
  }
end

-- Initialize default helpers immediately on module load.
M.update_helpers()

return M
