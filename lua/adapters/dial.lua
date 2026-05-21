-- Dial adapter (OpenAI-compatible, Api-Key auth, no model list fetch on start)
local openai = require("codecompanion.adapters.http.openai")

---@class CodeCompanion.HTTPAdapter.Dial: CodeCompanion.HTTPAdapter
return {
  name = "dial",
  formatted_name = "Dial",
  roles = {
    llm = "assistant",
    user = "user",
    tool = "tool",
  },
  opts = {
    stream = true,
    tools = true,
    vision = true,
  },
  features = {
    text = true,
    tokens = true,
  },
  url = "${url}/deployments/${deployment}/chat/completions",
  env = {
    api_key = "DIAL_API_KEY",
    url = "DIAL_ENDPOINT",
    deployment = "schema.model.default",
  },
  headers = {
    ["Content-Type"] = "application/json",
    ["Api-Key"] = "${api_key}",
  },
  handlers = {
    setup = function(self)
      if self.opts and self.opts.stream then
        self.parameters.stream = true
        self.parameters.stream_options = { include_usage = true }
      end
      return true
    end,
    tokens = function(self, data)
      return openai.handlers.tokens(self, data)
    end,
    form_parameters = function(self, params, messages)
      return openai.handlers.form_parameters(self, params, messages)
    end,
    form_messages = function(self, messages)
      return openai.handlers.form_messages(self, messages)
    end,
    form_tools = function(self, tools)
      return openai.handlers.form_tools(self, tools)
    end,
    chat_output = function(self, data, tools)
      return openai.handlers.chat_output(self, data, tools)
    end,
    inline_output = function(self, data, context)
      return openai.handlers.inline_output(self, data, context)
    end,
    tools = {
      format_tool_calls = function(self, tools)
        return openai.handlers.tools.format_tool_calls(self, tools)
      end,
      output_response = function(self, tool_call, output)
        return openai.handlers.tools.output_response(self, tool_call, output)
      end,
    },
    on_exit = function(self, data)
      return openai.handlers.on_exit(self, data)
    end,
  },
  schema = {
    model = {
      order = 1,
      mapping = "parameters",
      type = "string",
      desc = "Dial deployment/model name",
      default = "",
    },
    temperature = {
      order = 2,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 1,
      desc = "Sampling temperature (0-2)",
      validate = function(n)
        return n >= 0 and n <= 2, "Must be between 0 and 2"
      end,
    },
    max_tokens = {
      order = 3,
      mapping = "parameters",
      type = "integer",
      optional = true,
      default = nil,
      desc = "Maximum tokens to generate",
      validate = function(n)
        return n > 0, "Must be greater than 0"
      end,
    },
  },
}
