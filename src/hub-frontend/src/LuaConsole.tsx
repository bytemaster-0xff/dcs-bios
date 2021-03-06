import 'codemirror/lib/codemirror.css'
import 'codemirror/theme/material.css'
import 'codemirror/mode/lua/lua'
import 'codemirror/mode/javascript/javascript'

import React from 'react';
import { Controlled as CodeMirror } from 'react-codemirror2';
import { getApiConnection } from './ApiConnection';
import { LuaConsoleStatus } from './Status'

type LuaSnippetState = {
    luaEnvironment: string
    code: string
    responseStatus: string
    responseText: string
    readyToExecute: boolean
}

class LuaSnippet extends React.Component<{}, LuaSnippetState> {
    constructor(props: {}) {
        super(props)
        this.state = {
            luaEnvironment: "hub",
            code: "",
            responseStatus: "",
            responseText: "",
            readyToExecute: true,
        }
    }

    onKeyPress = (src: any, event:any) => {
        if (event.ctrlKey && event.keyCode === 13) {
            this.executeSnippet()
        }
    }

    executeSnippet = () => {
        if (!this.state.readyToExecute) return;
        this.setState({
            readyToExecute: false
        })
        let conn = getApiConnection()
        conn.onopen = () => {
            conn.send(JSON.stringify({
                datatype:"execute_lua_snippet",
                data: {
                    luaEnvironment: this.state.luaEnvironment,
                    luaCode: this.state.code
                }
            }))
        }
        conn.onmessage = (result) => {
            let msg = JSON.parse(result.data)
            conn.close()
            console.log(result, "ready to exec again")
            if (msg.datatype === "error") {
                this.setState({
                    responseStatus: "error",
                    responseText: msg.data.message,
                    readyToExecute: true
                })
                return
            }
            this.setState({
                responseStatus: msg.data.status,
                responseText: msg.data.result,
                readyToExecute: true
            })
        }
    }

    render() {
        return (
            <div>
                <LuaConsoleStatus/>

                <b>Lua Environment:</b> <select value={this.state.luaEnvironment} onChange={(e) => {this.setState({ luaEnvironment: e.target.value });}}>
                    <option value="hub">hub</option>
                    <option value="mission">mission</option>
                    <option value="export">export</option>
                    <option value="gui">gui</option>
                    </select> 
                <br/>
                <CodeMirror
                    value={this.state.code}
                    options={{
                        mode: 'lua',
                        lineNumbers: true
                    }}
                    onBeforeChange={(editor, data, value) => {this.setState({code: value}); }}
                    onKeyPress={this.onKeyPress} /><br/>
                <button onClick={this.executeSnippet} disabled={!this.state.readyToExecute}>Execute</button>
                &nbsp;&nbsp;Enter the code above, then click the button or press Ctrl+Enter.
                <hr/>
                Response: {this.state.responseStatus} 
                <CodeMirror
                    value={this.state.responseText}
                    options={{
                        lineNumbers: true
                    }}
                    onBeforeChange={(editor, data, value) => {}} />

            </div>
        )
    }
}

export { LuaSnippet }
