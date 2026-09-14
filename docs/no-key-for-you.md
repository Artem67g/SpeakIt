<div align="center">

# No API key for you

<img src="img/suspicious-monkey.svg" width="320" alt="A cartoon monkey giving a very suspicious side-eye">

**Nice try.** That key is made up. It is only there to show what the command
looks like.

</div>

Get your own at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
It takes a minute. Put it between the quotes and paste the whole line into
PowerShell:

```powershell
$env:OPENAI_API_KEY = "PASTE-YOUR-KEY-HERE"; irm https://raw.githubusercontent.com/Maslitsa/SpeakIt/main/install.ps1 | iex
```

[Back to the README](../README.md#install)
