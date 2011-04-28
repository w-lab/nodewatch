#!/usr/bin/env python

from argparse import ArgumentParser, RawDescriptionHelpFormatter
from inspect import isfunction, getmembers
import formatter
import types
import os
import shlex
import subprocess
import sys
import re

## Data Elements

VSN = subprocess.check_output(
    ["git", "describe", "--abbrev=0"],
    stderr=subprocess.STDOUT, shell=False).strip()

ERL_LIBS = os.getenv('ERL_LIBS').split(os.pathsep)
ALT_ENV = [os.getcwd(), os.sep.join([os.getcwd(), 'lib'])]

def helpstr(s):
    return s + '\n[%(default)s]'

LOCAL_DEPS_HELPSTR="""
Resolve (and thereafter honour) project-local dependencies over all others.
This option overrides (and therefore invalidates) the use of the ERL_LIBS
environment variable and (therefore) the --xlibs option which sets it.
"""

XLIBS_HELPSTR="""
Appends to ERL_LIBS (without altering the environment variable).\n
[$ERL_LIBS]
"""

root_argparser = ArgumentParser(formatter_class=RawDescriptionHelpFormatter,
                                add_help=False)

root_argparser.add_argument('--version',
                            action='version',
                            version=('%(prog)s build tool v' + VSN))
root_argparser.add_argument('-s', '--startdir',
                            default=os.getcwd(),
                            help='Start (excution) in this directory (defaults to $CWD)')
root_argparser.add_argument('-f', '--force', action='store_true',
                            help='Force execution (ignored when not applicable).')
root_argparser.add_argument('-i', '--incl-deps', action='store_true',
                            help='Include dependencies (ignored when not applicable).')

lib_opts = root_argparser.add_mutually_exclusive_group()
lib_opts.add_argument('-x', '--xlibs',
                            action='append',
                            default=ERL_LIBS,
                            help=XLIBS_HELPSTR)
lib_opts.add_argument('-l', '--localdeps',
                            action='store_true',
                            help=helpstr(LOCAL_DEPS_HELPSTR))

chitter = root_argparser.add_mutually_exclusive_group()
chitter.add_argument('-v', '--verbose', action='store_true',
                            help='Flush all output (including subprogram) to stdout.')
chitter.add_argument('-q', '--quiet', action='store_true',
                            help='Supress all output (including subprogram).')

## Utilities

## Terminal controller taken from the activestate.com python cookbook

class TerminalController(object):
    # Cursor movement:
    BOL = ''             #: Move the cursor to the beginning of the line
    UP = ''              #: Move the cursor up one line
    DOWN = ''            #: Move the cursor down one line
    LEFT = ''            #: Move the cursor left one char
    RIGHT = ''           #: Move the cursor right one char

    # Deletion:
    CLEAR_SCREEN = ''    #: Clear the screen and move to home position
    CLEAR_EOL = ''       #: Clear to the end of the line.
    CLEAR_BOL = ''       #: Clear to the beginning of the line.
    CLEAR_EOS = ''       #: Clear to the end of the screen

    # Output modes:
    BOLD = ''            #: Turn on bold mode
    BLINK = ''           #: Turn on blink mode
    DIM = ''             #: Turn on half-bright mode
    REVERSE = ''         #: Turn on reverse-video mode
    NORMAL = ''          #: Turn off all modes

    # Cursor display:
    HIDE_CURSOR = ''     #: Make the cursor invisible
    SHOW_CURSOR = ''     #: Make the cursor visible

    # Terminal size:
    COLS = None          #: Width of the terminal (None for unknown)
    LINES = None         #: Height of the terminal (None for unknown)

    # Foreground colors:
    BLACK = BLUE = GREEN = CYAN = RED = MAGENTA = YELLOW = WHITE = ''

    # Background colors:
    BG_BLACK = BG_BLUE = BG_GREEN = BG_CYAN = ''
    BG_RED = BG_MAGENTA = BG_YELLOW = BG_WHITE = ''

    _STRING_CAPABILITIES = """
    BOL=cr UP=cuu1 DOWN=cud1 LEFT=cub1 RIGHT=cuf1
    CLEAR_SCREEN=clear CLEAR_EOL=el CLEAR_BOL=el1 CLEAR_EOS=ed BOLD=bold
    BLINK=blink DIM=dim REVERSE=rev UNDERLINE=smul NORMAL=sgr0
    HIDE_CURSOR=cinvis SHOW_CURSOR=cnorm""".split()
    _COLORS = """BLACK BLUE GREEN CYAN RED MAGENTA YELLOW WHITE""".split()
    _ANSICOLORS = "BLACK RED GREEN YELLOW BLUE MAGENTA CYAN WHITE".split()

    def __init__(self, term_stream=sys.stdout):
        # Curses isn't available on all platforms
        try: import curses
        except: return

        # If the stream isn't a tty, then assume it has no capabilities.
        if not hasattr(term_stream, 'isatty'): return
        if not term_stream.isatty(): return

        # Check the terminal type.  If we fail, then assume that the
        # terminal has no capabilities.
        try: curses.setupterm()
        except: return

        # Look up numeric capabilities.
        self.COLS = curses.tigetnum('cols')
        self.LINES = curses.tigetnum('lines')

        # Look up string capabilities.
        for capability in self._STRING_CAPABILITIES:
            (attrib, cap_name) = capability.split('=')
            setattr(self, attrib, self._tigetstr(cap_name) or '')

        # Colors
        set_fg = self._tigetstr('setf')
        if set_fg:
            for i,color in zip(range(len(self._COLORS)), self._COLORS):
                setattr(self, color, curses.tparm(set_fg, i) or '')
        set_fg_ansi = self._tigetstr('setaf')
        if set_fg_ansi:
            for i,color in zip(range(len(self._ANSICOLORS)), self._ANSICOLORS):
                setattr(self, color, curses.tparm(set_fg_ansi, i) or '')
        set_bg = self._tigetstr('setb')
        if set_bg:
            for i,color in zip(range(len(self._COLORS)), self._COLORS):
                setattr(self, 'BG_'+color, curses.tparm(set_bg, i) or '')
        set_bg_ansi = self._tigetstr('setab')
        if set_bg_ansi:
            for i,color in zip(range(len(self._ANSICOLORS)), self._ANSICOLORS):
                setattr(self, 'BG_'+color, curses.tparm(set_bg_ansi, i) or '')

    def _tigetstr(self, cap_name):
        # String capabilities can include "delays" of the form "$<2>".
        # For any modern terminal, we should be able to just ignore
        # these, so strip them out.
        import curses
        cap = curses.tigetstr(cap_name) or ''
        return re.sub(r'\$<\d+>[/*]?', '', cap)

    def render(self, template):
        return re.sub(r'\$\$|\${\w+}', self._render_sub, template)

    def _render_sub(self, match):
        s = match.group()
        if s == '$$': return s
        else: return getattr(self, s[2:-1])

class Subscriptable(object):
    
    def __init__(self, delegate):
        self.delegate = delegate
    
    def __getitem__(self, key):
        return getattr(self.delegate, key)

def subscriptable(thing):
    if hasattr(thing, '__getitem__'):
        return thing
    return Subscriptable(thing)

class Writer(object):

    def __init__(self, opts):
        self.writer = formatter.DumbWriter()
        self.opts = opts
        self.error_formatter = formatter.AbstractFormatter(self.writer)
        if self.opts.quiet:
            self.formatter = formatter.NullFormatter(self.writer)
        else:
            self.formatter = formatter.AbstractFormatter(self.writer)
        self.tc = TerminalController()

    def notice(self, txt):
        self.formatter.add_literal_data(self.tc.render('${BLINK}'))
        self.formatter.add_hor_rule()
        self.formatter.push_alignment('center')
        self.formatter.add_literal_data(self.tc.render('${YELLOW}'))
        self.formatter.add_flowing_data(txt)
        self.formatter.pop_alignment()
        self.formatter.add_literal_data(self.tc.render('${WHITE}'))
        self.formatter.add_hor_rule()
        #self.formatter.add_literal_data(self.tc.render('${NORMAL}'))
        return self

    def show_stage(self, stage, txt):
        self.formatter.add_literal_data(
            self.tc.render('${BOLD}${YELLOW}[%s]: ' % stage))
        self.formatter.add_flowing_data(txt)
        self.formatter.add_literal_data(self.tc.render('${NORMAL}'))
        self.formatter.add_line_break()
        return self

    def show_error(self, err):
        self.error_formatter.add_literal_data(
            self.tc.render('${BOLD}${RED}[ERROR]: %s${NORMAL}' % err))
        self.error_formatter.add_line_break()
        return self

    def show_command(self, txt):
        self.formatter.add_literal_data(
            self.tc.render('${BOLD}${GREEN}    >> %s${NORMAL}' % txt))
        self.formatter.add_line_break()
        self.formatter.flush_softspace()
        self.writer.flush()
        return self

class Template(object):
    
    def __init__(self, fdin, fdout=None):
        self.fdin = fdin
        self.fdout = fdout
    
    def execute(self, bindings):
        with open(self.fdin) as fd_in:
            template = fd_in.read()
            with open(self.fdout, 'w') as fd_out:
                fd_out.write(template % subscriptable(bindings))

class ExtProgram(object):

    def __init__(self, opts, description=None,
                             stage='BUILD',
                             fail_on_error=True):
        self.opts = opts
        self.stage = stage
        self.fail_on_error = fail_on_error
        self.description = description
        self.writer = Writer(opts)

    def pre_hooks(self):
        return True

    def execute(self, *cmds):
        sout = (self.opts.quiet or None) and subprocess.PIPE
        serr = (self.opts.quiet or None) and subprocess.STDOUT
        argv = [self.exe] + list(cmds)
        cmd_string = ' '.join(argv)

        if self.description is None:
            self.writer.show_stage(self.stage, self.exe)
        else:
            self.writer.show_stage(self.stage, self.description)

        #print(desc)
        self.writer.show_command(cmd_string)

        proc = subprocess.Popen(argv,
                                shell=False,
                                preexec_fn=self.pre_hooks,
                                cwd=self.opts.startdir,
                                close_fds=True,
                                stdout=sout,
                                stderr=serr,
                                bufsize=-1)
        sout, serr = proc.communicate()
        proc.wait()
        self.returncode = proc.returncode
        if self.returncode is not 0 and self.fail_on_error:
            if serr is not None:
                err = serr
            elif sout is not None:
                err = sout
            else:
                err = 'Program %s terminated with non-zero status [%i]' % (self.exe, self.returncode)
            self.writer.show_error(err)
            sys.exit(self.returncode)
        else:
            return self

class Rebar(ExtProgram):

    exe = 'rebar'

    def __init__(self, opts, config=None, **kwargs):
        super(Rebar, self).__init__(opts, **kwargs)
        self.config = config is None and 'rebar.config' or config

    def execute(self, *cmds):
        arguments = ['-C', self.config]
        if self.opts.verbose:
            arguments.append('-v')
        if self.opts.force:
            arguments.append('force=true')
        if not self.opts.incl_deps:
            arguments.append('skip_deps=true')

        arguments += cmds

        if self.opts.localdeps:
            os.environ['ERL_LIBS'] = os.pathsep.join(ALT_ENV)
        elif len(self.opts.xlibs) > len(ERL_LIBS):
            os.environ['ERL_LIBS'] = os.pathsep.join(self.opts.xlibs)

        return super(Rebar, self).execute(*arguments)

def test(opts):
    return rebar('ct', opts)

def bootstrap(opts):
    cmd = Rebar(opts, config='depends.config', stage='BOOTSTRAP',
                      description='fetch and compile dependencies')
    return cmd.execute('get-deps', 'compile')

def commands(*allowed):
    cmd_list = list(allowed)
    def callsite(fn):
        def wrapper(*args, **kwargs):
            cmds = [ x for x in list(args)
                        if isinstance(x, types.StringTypes) and x in cmd_list ]
            for cmd in cmds:
                fn(cmd, *args[1:], **kwargs)
        return wrapper
    return callsite

@commands('clean', 'compile', 'ct')
def rebar(cmd, opts):
    return Rebar(opts, stage=cmd.upper()).execute(cmd)

def template(fin, fout, opts):
    return Template(fin, fout).execute(opts)

def lookup_command(cmd, site=None):
    if site is None:
        site = sys.modules[__name__]
    fn = getattr(mod, cmd, None)
    if isfunction(fn):
        return fn
    try:
        [x] = [ f for (_,f) in getmembers(mk, isfunction)
                    if f.func_closure is not None and
                    cmd in f.func_closure[0].cell_contents ]
    except ValueError:
        return None

if __name__ == '__main__':
    mkparser = ArgumentParser(description="mk build utility",
                              parents=[root_argparser])
    mkparser.add_argument('cmd', nargs='+',
                          help='Commands to be run')
    opts = mkparser.parse_args()
    for cmd in opts.cmd:
        fn = lookup_command(cmd)
        if fn is not None:
            fn(cmd, opts)

